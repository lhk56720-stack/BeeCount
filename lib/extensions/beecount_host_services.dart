import 'dart:async';

import 'package:beecount_extension_api/beecount_extension_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/db.dart';
import '../data/repositories/base_repository.dart';
import '../providers.dart';
import '../providers/security_providers.dart';
import '../services/system/logger_service.dart';

/// Adapts BeeCount internals to the narrow extension API.
///
/// Drift, Riverpod and page objects never leave this file.
final class BeeCountHostServicesFactory {
  const BeeCountHostServicesFactory(this._container);

  final ProviderContainer _container;

  HostServices create() {
    final repository = _container.read(repositoryProvider);
    return HostServices(
      ledgers: _BeeCountLedgerPort(repository, _container),
      accounts: _BeeCountAccountPort(repository),
      categories: _BeeCountCategoryPort(repository),
      transactions: _BeeCountTransactionPort(repository),
      clock: const _SystemClockPort(),
      lock: _BeeCountLockPort(_container),
      navigation: const _UnavailableNavigationPort(),
      logger: const _BeeCountSafeLogger(),
    );
  }
}

final class _BeeCountLedgerPort implements LedgerPort {
  const _BeeCountLedgerPort(this._repository, this._container);

  final BaseRepository _repository;
  final ProviderContainer _container;

  @override
  Future<LedgerSummary?> getCurrentLedger() async {
    final id = _container.read(currentLedgerIdProvider);
    final ledger = await _repository.getLedgerById(id);
    return ledger == null ? null : _ledgerSummary(ledger);
  }

  @override
  Future<LedgerSummary?> getLedger(String ledgerId) async {
    final id = int.tryParse(ledgerId);
    if (id == null) return null;
    final ledger = await _repository.getLedgerById(id);
    return ledger == null ? null : _ledgerSummary(ledger);
  }

  @override
  Future<List<LedgerSummary>> listLedgers() async {
    final ledgers = await _repository.getAllLedgers();
    return ledgers.map(_ledgerSummary).toList(growable: false);
  }
}

final class _BeeCountAccountPort implements AccountPort {
  const _BeeCountAccountPort(this._repository);

  final BaseRepository _repository;

  @override
  Future<AccountSummary?> getAccount(String accountId) async {
    final id = int.tryParse(accountId);
    if (id == null) return null;
    final account = await _repository.getAccount(id);
    return account == null ? null : _accountSummary(account);
  }

  @override
  Future<List<AccountSummary>> listAccounts({
    required String ledgerId,
    String? currency,
  }) async {
    final ledger = int.tryParse(ledgerId);
    if (ledger == null) return const <AccountSummary>[];
    final accounts = await _repository.getAvailableAccountsForLedger(ledger);
    return accounts
        .where((account) => currency == null || account.currency == currency)
        .map(_accountSummary)
        .toList(growable: false);
  }
}

final class _BeeCountCategoryPort implements CategoryPort {
  const _BeeCountCategoryPort(this._repository);

  final BaseRepository _repository;

  @override
  Future<CategorySummary?> getCategory(String categoryId) async {
    final id = int.tryParse(categoryId);
    if (id == null) return null;
    final category = await _repository.getCategoryById(id);
    return category == null ? null : _categorySummary(category);
  }

  @override
  Future<List<CategorySummary>> listUsableCategories({
    required String ledgerId,
    required AutomationDirection direction,
  }) async {
    final kind =
        direction == AutomationDirection.expense ? 'expense' : 'income';
    final categories = await _repository.getUsableCategories(kind);
    return categories.map(_categorySummary).toList(growable: false);
  }
}

final class _BeeCountTransactionPort implements TransactionPort {
  _BeeCountTransactionPort(this._repository);

  static const _automationNamespace = 'b3e7c0de-0000-4000-8000-beec00000002';
  static const _uuid = Uuid();

  final BaseRepository _repository;
  Future<void> _serial = Future<void>.value();

  @override
  Future<HostTransactionSummary?> getTransaction(String transactionId) async {
    final id = int.tryParse(transactionId);
    if (id == null) return null;
    final transaction = await _repository.getTransactionById(id);
    return transaction == null
        ? null
        : await _transactionSummary(transaction, _repository);
  }

  @override
  Future<List<HostTransactionSummary>> listRecentTransactions({
    required String ledgerId,
    required DateTime from,
    required DateTime to,
  }) async {
    final id = int.tryParse(ledgerId);
    if (id == null) return const <HostTransactionSummary>[];
    final rows = await _repository.getRecentTransactionsWithCategory(
      ledgerId: id,
      limit: 200,
    );
    final results = <HostTransactionSummary>[];
    for (final row in rows) {
      final transaction = row.t;
      if (transaction.happenedAt.isBefore(from) ||
          transaction.happenedAt.isAfter(to)) {
        continue;
      }
      results.add(await _transactionSummary(transaction, _repository));
    }
    return results;
  }

  @override
  Future<PostingResult> postCandidate(PostingCommand command) {
    final completer = Completer<PostingResult>();
    _serial = _serial.then((_) async {
      try {
        completer.complete(await _postSerial(command));
      } catch (_) {
        completer.complete(
          const PostingResult(
            status: PostingResultStatus.rejected,
            safeErrorCode: 'host.transaction_write_failed',
          ),
        );
      }
    });
    return completer.future;
  }

  Future<PostingResult> _postSerial(PostingCommand command) async {
    final ledgerId = int.tryParse(command.ledgerId);
    final accountId = int.tryParse(command.accountId);
    final categoryId =
        command.categoryId == null ? null : int.tryParse(command.categoryId!);
    final toAccountId =
        command.toAccountId == null ? null : int.tryParse(command.toAccountId!);
    if (ledgerId == null ||
        accountId == null ||
        (command.categoryId != null && categoryId == null) ||
        (command.toAccountId != null && toAccountId == null)) {
      return const PostingResult(
        status: PostingResultStatus.rejected,
        safeErrorCode: 'host.invalid_identifier',
      );
    }
    final syncId = _uuid.v5(_automationNamespace, command.idempotencyKey);
    final existing = await _repository.getTransactionBySyncId(syncId);
    if (existing != null) {
      if (_matchesCommand(existing, command)) {
        return PostingResult(
          status: PostingResultStatus.alreadyApplied,
          transactionId: existing.id.toString(),
        );
      }
      return const PostingResult(
        status: PostingResultStatus.idempotencyConflict,
        safeErrorCode: 'host.idempotency_conflict',
      );
    }
    final id = await _repository.addTransaction(
      ledgerId: ledgerId,
      type: _hostType(command.hostType),
      amount: command.amountMinor / 100,
      categoryId: categoryId,
      accountId: accountId,
      toAccountId: toAccountId,
      happenedAt: command.occurredAt,
      note: command.note,
      syncId: syncId,
      categorySyncIdOverride: null,
      accountSyncIdOverride: null,
      toAccountSyncIdOverride: null,
      currencyCode: command.currency,
    );
    return PostingResult(
      status: PostingResultStatus.created,
      transactionId: id.toString(),
    );
  }
}

final class _SystemClockPort implements ClockPort {
  const _SystemClockPort();

  @override
  DateTime get now => DateTime.now().toUtc();
}

final class _BeeCountLockPort implements LockPort {
  const _BeeCountLockPort(this._container);

  final ProviderContainer _container;

  @override
  Future<bool> isLocked() async => _container.read(isAppLockedProvider);

  @override
  Future<bool> requestUnlock({required String reason}) async => false;
}

final class _UnavailableNavigationPort implements NavigationPort {
  const _UnavailableNavigationPort();

  @override
  Future<void> openCandidate({required String candidateId}) async {}

  @override
  Future<void> openCandidateList() async {}

  @override
  Future<void> openTransaction({required String transactionId}) async {}
}

final class _BeeCountSafeLogger implements SafeLogger {
  const _BeeCountSafeLogger();

  @override
  void debug(String code, {Map<String, Object?> fields = const {}}) =>
      logger.debug('Extensions', code);

  @override
  void error(String code, {Map<String, Object?> fields = const {}}) =>
      logger.error('Extensions', code);

  @override
  void warning(String code, {Map<String, Object?> fields = const {}}) =>
      logger.warning('Extensions', code);
}

LedgerSummary _ledgerSummary(Ledger ledger) => LedgerSummary(
      id: ledger.id.toString(),
      name: ledger.name,
      baseCurrency: ledger.currency,
      isWritable: ledger.myRole != 'viewer',
    );

AccountSummary _accountSummary(Account account) => AccountSummary(
      id: account.id.toString(),
      name: account.name,
      currency: account.currency,
      isEnabled: !account.hidden,
      maskedIdentifier:
          account.cardLastFour == null ? null : '****${account.cardLastFour}',
    );

CategorySummary _categorySummary(Category category) => CategorySummary(
      id: category.id.toString(),
      name: category.name,
      direction: category.kind == 'expense'
          ? AutomationDirection.expense
          : AutomationDirection.income,
      isUsable: category.level == 1 || category.level == 2,
    );

Future<HostTransactionSummary> _transactionSummary(
  Transaction transaction,
  BaseRepository repository,
) async {
  final ledger = await repository.getLedgerById(transaction.ledgerId);
  return HostTransactionSummary(
    id: transaction.id.toString(),
    ledgerId: transaction.ledgerId.toString(),
    occurredAt: transaction.happenedAt.toUtc(),
    amountMinor: (transaction.amount * 100).round(),
    currency: transaction.currencyCode ?? ledger?.currency ?? 'CNY',
    hostType: switch (transaction.type) {
      'income' => HostTransactionType.income,
      'transfer' => HostTransactionType.transfer,
      _ => HostTransactionType.expense,
    },
    direction: switch (transaction.type) {
      'income' => AutomationDirection.income,
      'transfer' => AutomationDirection.transfer,
      _ => AutomationDirection.expense,
    },
    accountId: transaction.accountId?.toString(),
    toAccountId: transaction.toAccountId?.toString(),
    merchant: null,
    stableTransactionIdHash: transaction.syncId,
  );
}

bool _matchesCommand(Transaction transaction, PostingCommand command) =>
    transaction.ledgerId.toString() == command.ledgerId &&
    transaction.type == _hostType(command.hostType) &&
    (transaction.amount * 100).round() == command.amountMinor &&
    transaction.accountId?.toString() == command.accountId &&
    transaction.toAccountId?.toString() == command.toAccountId &&
    transaction.categoryId?.toString() == command.categoryId &&
    transaction.happenedAt.toUtc().millisecondsSinceEpoch ==
        command.occurredAt.toUtc().millisecondsSinceEpoch;

String _hostType(HostTransactionType type) => switch (type) {
      HostTransactionType.expense => 'expense',
      HostTransactionType.income => 'income',
      HostTransactionType.transfer => 'transfer',
    };

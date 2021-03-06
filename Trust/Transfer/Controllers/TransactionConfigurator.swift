// Copyright SIX DAY LLC. All rights reserved.

import Foundation
import BigInt
import Result
import TrustCore
import TrustKeystore
import JSONRPCKit
import APIKit

public struct PreviewTransaction {
    let value: BigInt
    let account: Account
    let address: Address?
    let contract: Address?
    let nonce: BigInt
    let data: Data
    let gasPrice: BigInt
    let gasLimit: BigInt
    let transferType: TransferType
}

class TransactionConfigurator {

    let session: WalletSession
    let account: Account
    let transaction: UnconfirmedTransaction
    var configuration: TransactionConfiguration {
        didSet {
            configurationUpdate.value = configuration
        }
    }
    var requestEstimateGas: Bool

    var configurationUpdate: Subscribable<TransactionConfiguration> = Subscribable(nil)

    init(
        session: WalletSession,
        account: Account,
        transaction: UnconfirmedTransaction
    ) {
        self.session = session
        self.account = account
        self.transaction = transaction
        self.requestEstimateGas = transaction.gasLimit == .none

        let nonce = transaction.nonce ?? BigInt(session.nonceProvider.nextNonce ?? -1)
        let data: Data = TransactionConfigurator.data(for: transaction)
        let calculatedGasLimit = transaction.gasLimit ?? TransactionConfigurator.gasLimit(for: transaction.transferType)
        let calculatedGasPrice = min(max(transaction.gasPrice ?? session.chainState.gasPrice ?? GasPriceConfiguration.default, GasPriceConfiguration.min), GasPriceConfiguration.max)

        self.configuration = TransactionConfiguration(
            gasPrice: calculatedGasPrice,
            gasLimit: calculatedGasLimit,
            data: data,
            nonce: nonce
        )
    }

    private static func data(for transaction: UnconfirmedTransaction) -> Data {
        switch transaction.transferType {
        case .ether, .dapp:
            return transaction.data ?? Data()
        case .token:
            return ERC20Encoder.encodeTransfer(to: transaction.to!, tokens: transaction.value.magnitude)
        }
    }

    private static func gasLimit(for type: TransferType) -> BigInt {
        switch type {
        case .ether:
            return GasLimitConfiguration.default
        case .token:
            return GasLimitConfiguration.tokenTransfer
        case .dapp:
            return GasLimitConfiguration.dappTransfer
        }
    }

    private static func gasPrice(for type: TransferType) -> BigInt {
        return GasPriceConfiguration.default
    }

    func load(completion: @escaping (Result<Void, AnyError>) -> Void) {
        if requestEstimateGas {
            estimateGasLimit()
        }
        loadNonce(completion: completion)
    }

    func estimateGasLimit() {
        let request = EstimateGasRequest(transaction: signTransaction())
        Session.send(EtherServiceRequest(batch: BatchFactory().create(request))) { [weak self] result in
            guard let `self` = self else { return }
            switch result {
            case .success(let gasLimit):
                let gasLimit: BigInt = {
                    let limit = BigInt(gasLimit.drop0x, radix: 16) ?? BigInt()
                    if limit == BigInt(21000) {
                        return limit
                    }
                    return limit + (limit * 20 / 100)
                }()
                self.refreshGasLimit(gasLimit)
            case .failure(let error):
                NSLog("estimateGasLimit \(error)")
            }
        }
    }

    // combine into one function

    func refreshGasLimit(_ gasLimit: BigInt) {
        configuration = TransactionConfiguration(
            gasPrice: configuration.gasPrice,
            gasLimit: gasLimit,
            data: configuration.data,
            nonce: configuration.nonce
        )
    }

    func refreshNonce(_ nonce: BigInt) {
        configuration = TransactionConfiguration(
            gasPrice: configuration.gasPrice,
            gasLimit: configuration.gasLimit,
            data: configuration.data,
            nonce: nonce
        )
    }

    func loadNonce(completion: @escaping (Result<Void, AnyError>) -> Void) {
        session.nonceProvider.getNextNonce(force: false) { [weak self] result in
            switch result {
            case .success(let nonce):
                self?.refreshNonce(nonce)
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    func valueToSend() -> BigInt {
        var value = transaction.value
        if let balance = session.balance?.value,
            balance == transaction.value {
            value = transaction.value - configuration.gasLimit * configuration.gasPrice
            //We work only with positive numbers.
            if value.sign == .minus {
                value = BigInt(value.magnitude)
            }
        }
        return value
    }

    func previewTransaction() -> PreviewTransaction {
        return PreviewTransaction(
            value: valueToSend(),
            account: account,
            address: transaction.to,
            contract: .none,
            nonce: configuration.nonce,
            data: configuration.data,
            gasPrice: configuration.gasPrice,
            gasLimit: configuration.gasLimit,
            transferType: transaction.transferType
        )
    }

    func signTransaction() -> SignTransaction {
        let value: BigInt = {
            switch transaction.transferType {
            case .ether, .dapp: return valueToSend()
            case .token: return 0
            }
        }()
        let address: Address? = {
            switch transaction.transferType {
            case .ether, .dapp: return transaction.to
            case .token(let token): return token.address
            }
        }()
        let signTransaction = SignTransaction(
            value: value,
            account: account,
            to: address,
            nonce: configuration.nonce,
            data: configuration.data,
            gasPrice: configuration.gasPrice,
            gasLimit: configuration.gasLimit,
            chainID: session.config.chainID
        )

        return signTransaction
    }

    func update(configuration: TransactionConfiguration) {
        self.configuration = configuration
    }

    func balanceValidStatus() -> BalanceStatus {
        var etherSufficient = true
        var gasSufficient = true
        var tokenSufficient = true

        guard let balance = session.balance else {
            return .ether(etherSufficient: etherSufficient, gasSufficient: gasSufficient)
        }
        let transaction = previewTransaction()
        let totalGasValue = transaction.gasPrice * transaction.gasLimit

        //We check if it is ETH or token operation.
        switch transaction.transferType {
        case .ether, .dapp:
            if transaction.value > balance.value {
                etherSufficient = false
                gasSufficient = false
            } else {
                if totalGasValue + transaction.value > balance.value {
                    gasSufficient = false
                }
            }
            return .ether(etherSufficient: etherSufficient, gasSufficient: gasSufficient)
        case .token(let token):
            if totalGasValue > balance.value {
                etherSufficient = false
                gasSufficient = false
            }
            if transaction.value > token.valueBigInt {
                tokenSufficient = false
            }
            return .token(tokenSufficient: tokenSufficient, gasSufficient: gasSufficient)
        }
    }
}

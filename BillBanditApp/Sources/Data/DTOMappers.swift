import Foundation

extension MobileUser {
    func toDomain() -> UserProfile {
        UserProfile(
            id: id,
            name: name,
            email: email,
            imageURL: image.flatMap(URL.init(string:)),
            phone: phone,
            preferredName: preferredName,
            upiID: upiID,
            isProfileComplete: isProfileComplete ?? false
        )
    }
}

extension MobileMember {
    func toDomain(currentUserId: String?) -> TripParticipant {
        TripParticipant(
            id: userId,
            displayName: user.preferredName ?? user.name ?? user.email ?? userId,
            kind: userId == currentUserId ? .currentUser : .friend(friendId: userId)
        )
    }
}

extension MobileGroup {
    func toDomain(currentUserId: String? = nil) -> Trip {
        Trip(
            id: id,
            name: name,
            // The backend "group" record has no destination/startDate/endDate columns.
            // Preserve that absence as nil so UI cannot mistake API gaps for real trip metadata.
            destination: nil,
            startDate: nil,
            endDate: nil,
            currency: Currency(code: currency),
            participants: members.map { $0.toDomain(currentUserId: currentUserId) },
            status: status == .finalized ? .finalized : .active
        )
    }
}

extension MobileExpense {
    func toDomain() -> Expense {
        Expense(
            id: id,
            title: description,
            amount: Money(apiMajorUnitNumber: amount, currency: Currency(code: currency)),
            paidBy: paidById,
            date: date,
            category: category,
            notes: notes,
            includedParticipants: splits.map(\.userId),
            splitMethod: splitType.toDomain(splits: splits, currency: Currency(code: currency))
        )
    }
}

extension MobileExpense.SplitType {
    func toDomain(splits: [MobileExpense.Split], currency: Currency) -> SplitMethod {
        switch self {
        case .equal:
            return .equal
        case .exact:
            return .exactAmounts(
                Dictionary(uniqueKeysWithValues: splits.map {
                    ($0.userId, Money(apiMajorUnitNumber: $0.amount, currency: currency))
                })
            )
        case .percentage:
            return .percentages(
                Dictionary(uniqueKeysWithValues: splits.map {
                    ($0.userId, Decimal($0.percentage ?? 0))
                })
            )
        case .shares:
            return .shares(
                Dictionary(uniqueKeysWithValues: splits.map {
                    ($0.userId, $0.shares ?? 1)
                })
            )
        }
    }
}

extension Expense {
    func toAPIRequest(groupId: String?) throws -> UpsertExpenseRequest {
        let splits = try SplitEngine.splits(for: self)
        let splitType: MobileExpense.SplitType
        let splitRequests: [UpsertExpenseRequest.Split]

        switch splitMethod {
        case .equal:
            splitType = .equal
            splitRequests = splits.map { split in
                UpsertExpenseRequest.Split(
                    userId: split.participantId,
                    amount: split.amount.apiMajorUnitNumber,
                    percentage: nil,
                    shares: nil
                )
            }
        case .payerOnly:
            splitType = .exact
            splitRequests = splits.map { split in
                UpsertExpenseRequest.Split(
                    userId: split.participantId,
                    amount: split.amount.apiMajorUnitNumber,
                    percentage: nil,
                    shares: nil
                )
            }
        case .exactAmounts:
            splitType = .exact
            splitRequests = splits.map { split in
                UpsertExpenseRequest.Split(
                    userId: split.participantId,
                    amount: split.amount.apiMajorUnitNumber,
                    percentage: nil,
                    shares: nil
                )
            }
        case .percentages(let percentages):
            splitType = .percentage
            splitRequests = splits.map { split in
                UpsertExpenseRequest.Split(
                    userId: split.participantId,
                    amount: split.amount.apiMajorUnitNumber,
                    percentage: percentages[split.participantId].map { NSDecimalNumber(decimal: $0).doubleValue },
                    shares: nil
                )
            }
        case .shares(let shares):
            splitType = .shares
            splitRequests = splits.map { split in
                UpsertExpenseRequest.Split(
                    userId: split.participantId,
                    amount: split.amount.apiMajorUnitNumber,
                    percentage: nil,
                    shares: shares[split.participantId]
                )
            }
        }

        return UpsertExpenseRequest(
            description: title,
            amount: amount.apiMajorUnitNumber,
            currency: amount.currency.code,
            date: date,
            category: category,
            groupId: groupId,
            paidById: paidBy,
            splitType: splitType,
            splits: splitRequests,
            notes: notes
        )
    }
}

extension MobileGroupBalances {
    func toDomain(currency: Currency = .inr) -> SettlementSummary {
        SettlementSummary(
            balances: netBalances.map {
                ParticipantBalance(
                    participantId: $0.userId,
                    paid: .zero(currency: currency),
                    owed: .zero(currency: currency),
                    net: Money(apiMajorUnitNumber: $0.netAmount, currency: currency)
                )
            },
            simplifiedInstructions: simplifiedDebts.map {
                SettlementInstruction(
                    from: $0.fromId,
                    to: $0.toId,
                    amount: Money(apiMajorUnitNumber: $0.amount, currency: currency)
                )
            }
        )
    }
}

extension MobileTransaction {
    func toDomain() -> Settlement {
        Settlement(
            id: id,
            from: sender.id,
            to: receiver.id,
            amount: Money(apiMajorUnitNumber: amount, currency: Currency(code: currency)),
            date: createdAt,
            note: note
        )
    }
}

//
//  SDKSynchronizer+StaticBirthday.swift
//
//  HS delta on top of upstream 2.7.0-rc.1: birthday estimation available without a Synchronizer
//  instance, for restore-by-date flows that run before any wallet/synchronizer exists.
//  Pure bundled-checkpoint lookups.

import Foundation

extension SDKSynchronizer {
    public static func estimateBirthdayHeight(for date: Date, isMainnet: Bool = true) -> BlockHeight {
        CheckpointSourceFactory.fromBundle(for: isMainnet ? .mainnet : .testnet).estimateBirthdayHeight(for: date)
    }

    public static func birthdayTime(for height: BlockHeight, isMainnet: Bool = true) -> UInt32 {
        CheckpointSourceFactory.fromBundle(for: isMainnet ? .mainnet : .testnet).birthday(for: height).time
    }
}

//
//  BiqDeviceFirmware.swift
//  BiqCollectorLib
//
//  Created by Kyle Jessup on 2018-06-26.
//

import Foundation
import SwiftCodables
import PerfectPostgreSQL
import PerfectCRUD

public extension BiqDeviceFirmware {
	public typealias DB = Database<PostgresDatabaseConfiguration>
	public enum FWType: Int {
		case esp = 1, efm = 0
	}
	public static func nextVersion(of type: FWType, from: String, _ db: DB) throws -> String? {
		guard let next = try db.table(BiqDeviceFirmware.self)
			.where(\BiqDeviceFirmware.version == from && \BiqDeviceFirmware.type == type.rawValue)
			.first() else {
			return nil // not in database - can not be upgraded
		}
		return next.obsoletedBy?.trimmingCharacters(in: CharacterSet.init(charactersIn: "\t\r\n "))
	}
	public static func latest(of type: FWType, _ db: DB) throws -> String? {
		guard let next = try db.table(BiqDeviceFirmware.self)
			.order(descending: \BiqDeviceFirmware.version)
			.where(\BiqDeviceFirmware.obsoletedBy == nil && \BiqDeviceFirmware.type == type.rawValue)
			.first() else {
				return nil // not in database - can not be upgraded
		}
		return next.version
	}
}

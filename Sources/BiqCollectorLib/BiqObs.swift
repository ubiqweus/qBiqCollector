//
//  BixObs.swift
//  BiqCollector
//
//  Created by Jonathan Guthrie on 2016-12-05.
//
//

import struct Foundation.UUID
import PerfectCloudFormation
import PerfectRedis
import PerfectCrypto
import PerfectCRUD
import PerfectPostgreSQL
import SwiftCodables

let obsAddMsgKey = "obs-add"

public struct BiqObs: Codable, TableNameProvider {
	public static var tableName = "obs"
	public static var reportSink: CloudFormation.ElastiCacheInstance?
	public static var databaseInfo: CloudFormation.RDSInstance? {
		didSet {
			guard let dbInfo = databaseInfo else {
				return
			}
			do {
				let db = try Database<PostgresDatabaseConfiguration>(
					configuration: .init(database: "biq",
										 host: dbInfo.hostName,
										 port: dbInfo.hostPort,
										 username: dbInfo.userName,
										 password: dbInfo.password))
				try db.create(BiqDeviceFirmware.self, primaryKey: \.version, policy: .reconcileTable)
				try db.create(BiqDevicePushLimit.self, policy: .reconcileTable)
					.index(unique: true, \.deviceId, \.limitType)
			} catch {
				CRUDLogging.log(.error, "\(error)")
			}
		}
	}
	// the db table is set to permit nulls for these, but the codables model does not have null properties and I think adding nulls would break it
	// so fix it when you can
	public var bixid: String = ""
	public var obstime: Double = 0
	public var charging: Int = 0
	public var firmware: String = ""
	public var wifiFirmware: String?
	public var battery: Double = 0
	public var temp: Double = 0
	public var light: Int = 0
	public var humidity: Int = 0
	public var accelx: Int = 0
	public var accely: Int = 0
	public var accelz: Int = 0
}

extension BiqObs {
	func asDataDict() -> [String:Any?] {
		return [
			"bixid":bixid,
			"obstime":obstime,
			"charging":charging,
			"firmware":firmware,
			"wifiFirmware":wifiFirmware,
			"battery":battery,
			"temp":temp,
			"light":light,
			"humidity":humidity,
			"accelx":accelx,
			"accely":accely,
			"accelz":accelz
		]
	}
	
	func save() throws -> [BiqResponseValue] {
		guard let dbInfo = BiqObs.databaseInfo else {
			throw PostgresCRUDError("Database info not set.")
		}
		let db = try Database<PostgresDatabaseConfiguration>(
			configuration: .init(database: "biq",
								 host: dbInfo.hostName,
								 port: dbInfo.hostPort,
								 username: dbInfo.userName,
								 password: dbInfo.password))
		try db.table(BiqObs.self).insert(self)
		// gather push limits
		let pushLimits: [BiqDevicePushLimit] = try db.transaction {
			let table = db.table(BiqDevicePushLimit.self)
			let whereClause = table.where(\BiqDevicePushLimit.deviceId == bixid)
			let all = try whereClause.select().map {$0}
			if !all.isEmpty {
				try whereClause.delete()
			}
			return all
		}
		var tempHigh: Float?
		var tempLow: Float?
		// convert into response values
		var values: [BiqResponseValue] = pushLimits.compactMap {
			limit in
			guard let type = limit.type else {
				return nil
			}
			switch type.rawValue {
			case BiqDeviceLimitType.tempHigh.rawValue:
				tempHigh = limit.limitValue
				return nil
			case BiqDeviceLimitType.tempLow.rawValue:
				tempLow = limit.limitValue
				return nil
			case BiqDeviceLimitType.movementLevel.rawValue:
				let value = UInt16(limit.limitValue)
				return .accelerometerThreshold(x: value, y: value, z: value)
			case BiqDeviceLimitType.colour.rawValue:
				guard let colour = Int(limit.limitValueString ?? "4C96FC", radix: 16) else {
					return nil
				}
				let b = UInt8(colour & 0xff), g = UInt8((colour >> 8) & 0xff), r = UInt8((colour >> 16) & 0xff)
				return .ledColour(r: r, g: g, b: b)
			case BiqDeviceLimitType.interval.rawValue:
				let interval = UInt16(limit.limitValue)
				return .reportInterval(interval)
			default:
				return nil
			}
		}
		
		if let tempHigh = tempHigh, let tempLow = tempLow {
			values.append(contentsOf: [.temperatureThreshold(low: Int16(tempLow * 10), high: Int16(tempHigh * 10))])
		}
		
		// firmware pushes always go last
		if let nextEFM = try BiqDeviceFirmware.nextVersion(of: .efm, from: firmware, db) {
			CRUDLogging.log(.info, "Sending want EFM update to \(bixid)@\(firmware)->\(nextEFM).")
			values.append(.updateBootFW(""))
		} else if let wifiFirmware = self.wifiFirmware,
			let nextESP = try BiqDeviceFirmware.nextVersion(of: .esp, from: wifiFirmware, db) {
			CRUDLogging.log(.info, "Sending want ESP update to \(bixid)@\(wifiFirmware)->\(nextESP).")
			values.append(.updateAppFW(""))
		} else {
			CRUDLogging.log(.info, "No firmware for \(bixid)@esp:\(wifiFirmware ?? "")/efm:\(firmware).")
		}
		if !values.isEmpty {
			CRUDLogging.log(.info, "Sending response values \(values)")
		}
		return values
	}
	
	func reportSave() {
		guard let sink = BiqObs.reportSink else {
			return CRUDLogging.log(.info, "Redis info not set.")
		}
		do {
			let dataDict = asDataDict()
			let redisAddr = RedisClientIdentifier(withHost: sink.hostName, port: sink.hostPort)
			let redisClient = try RedisClient.getClient(withIdentifier: redisAddr)
			let objKey = "obs:\(UUID().uuidString)"
			var hash = RedisHash(redisClient, name: objKey)
			for (key, value) in dataDict {
				guard let value = value else {
					return
				}
				hash[key] = .string("\(value)")
			}
			redisClient.list(named: obsAddMsgKey).append(objKey)
			CRUDLogging.log(.info, "Added obs to redis queue")
		} catch {
			CRUDLogging.log(.error, "\(error)")
		}
	}
}

//
//  BixServer.swift
//
//  Created by Jonathan Guthrie on 2016-07-11.
//	Copyright (C) 2015 PerfectlySoft, Inc.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import Foundation
import BiqCollectorLib
import PerfectPostgreSQL
import Dispatch
import PerfectLib
import PerfectHTTP
import PerfectHTTPServer
import PerfectNet
import PerfectCrypto
import PerfectCloudFormation
import PerfectRedis
import PerfectCRUD
import SwiftCodables

extension String {
  func env(_ defaultValue: String = "" ) -> String {
    guard let pval = getenv(self) else { return defaultValue }
    return String.init(cString: pval)
  }
}

let biqDatabaseInfo: CloudFormation.RDSInstance = {
	if let pgsql = CloudFormation.listRDSInstances(type: .postgres)
		.sorted(by: { $0.resourceName < $1.resourceName }).first {
		return pgsql
	}
	return .init(resourceType: .postgres,
				 resourceId: "",
				 resourceName: "",
				 userName: "BIQ_PG_USER".env("postgres"),
				 password: "BIQ_PG_PASS".env(""),
				 hostName: "BIQ_PG_HOST".env("localhost"),
				 hostPort: Int("BIQ_PG_PORT".env("5432")) ?? 5432 )
}()

let biqRedisInfo: CloudFormation.ElastiCacheInstance = {
	if let redis = CloudFormation.listElastiCacheInstances(type: .redis)
		.sorted(by: { $0.resourceName < $1.resourceName }).first {
		return redis
	}
	return .init(resourceType: .redis,
				 resourceId: "",
				 resourceName: "",
				 hostName: "BIQ_RD_HOST".env("localhost"),
				 hostPort: Int("BIQ_RD_PORT".env("6379")) ?? 6379)
}()
CRUDLogging.queryLogDestinations = []
BiqObs.reportSink = biqRedisInfo
BiqObs.databaseInfo = biqDatabaseInfo

#if os(Linux)
let staticFilePort = 80
let testPort = 8080
let webroot = "./webroot"
#else
let staticFilePort = 80
let testPort = 8080
let webroot = "/Users/kjessup/development/TreeFrog/qBiq/qBiqCollector/webroot"
#endif

// static file server for updates
do {
	CRUDLogging.log(.info, "Binding static file server on port \(staticFilePort)")
	func fileServe(_ request: HTTPRequest, _ response: HTTPResponse) {
		let path = request.path
		if path.filePathExtension == "bin" {
			do {
				let dbInfo = biqDatabaseInfo
				let db = try Database<PostgresDatabaseConfiguration>(
					configuration: .init(database: "biq",
										 host: dbInfo.hostName,
										 port: dbInfo.hostPort,
										 username: dbInfo.userName,
										 password: dbInfo.password))
				
				let fileName = path.lastFilePathComponent
				let type: BiqDeviceFirmware.FWType
				if fileName.deletingFileExtension.hasPrefix("QBIQ_APP") {
					type = .efm
				} else if fileName.deletingFileExtension.hasPrefix("user") { // ESP
					type = .esp
				} else {
					return response.completed(status: .notFound)
				}
				let newPath: String
				if  let query = request.param(name: "qbiqid"),
						let lastObs = try db.table(BiqObs.self)
						.order(descending: \BiqObs.obstime).limit(1)
						.where(\BiqObs.bixid == query)
						.first() {
					let currentVersion: String
					if case .efm = type { // EFM
						currentVersion = lastObs.firmware
					} else { // ESP
						currentVersion = lastObs.wifiFirmware ?? ""
					}
					if !currentVersion.isEmpty,
						let next = try BiqDeviceFirmware.nextVersion(of: type, from: currentVersion, db) {
						newPath = "/\(next)/\(fileName)"
					} else {
						guard let latest = try BiqDeviceFirmware.latest(of: type, db) else {
							return response.completed(status: .notFound)
						}
						newPath = "/\(latest)/\(fileName)"
					}
				} else {
					guard let latest = try BiqDeviceFirmware.latest(of: type, db) else {
						return response.completed(status: .notFound)
					}
					newPath = "/\(latest)/\(fileName)"
				}
				CRUDLogging.log(.info, "Serving file \(newPath)")
				request.path = newPath
			} catch {
				CRUDLogging.log(.error, "\(error)")
			}
		}
		StaticFileHandler(documentRoot: webroot).handleRequest(request: request, response: response)
		CRUDLogging.log(.info, "Served file \(request.path)")// to \(request.remoteAddress.host)")
	}
	var r = Routes()
	r.add(method: .get, uri: "/**", handler: fileServe)
	r.add(method: .head, uri: "/**", handler: fileServe)
	try HTTPServer.launch(wait: false, name: "qbiq static files", port: staticFilePort, routes: r)
} catch {
	CRUDLogging.log(.error, "Unable to start static file server: \(error)")
}

// launch new server
let biqProtoServer = try BiqProtoServer(port: 8092)
try biqProtoServer.start(handleBiqProtoConnection)


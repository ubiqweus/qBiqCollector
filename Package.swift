// swift-tools-version:4.0
// Generated automatically by Perfect Assistant
// Date: 2018-04-27 13:55:38 +0000
import PackageDescription

let package = Package(
	name: "BiqCollector",
	products: [
		.executable(name: "biqcollector", targets: ["BiqCollectorExe"]),
		.library(name: "BiqCollectorLib", targets: ["BiqCollectorLib"])
	],
	dependencies: [
		.package(url: "https://github.com/PerfectlySoft/Perfect-Net.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-Thread.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/PerfectLib.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-PostgreSQL.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-HTTPServer", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-Notifications.git", from: "3.0.0"),
		.package(url: "https://github.com/PerfectlySoft/Perfect-CloudFormation.git", from: "0.0.0"),
		.package(url: "https://github.com/ubiqweus/qBiqSwiftCodables.git", .branch("master")),
		.package(url: "https://github.com/kjessup/SAuthCodables.git", .branch("master")),
	],
	targets: [
		.target(name: "BiqNetLib", dependencies:[]),
		.target(name: "BiqCollectorLib",
				dependencies: [
					"PerfectNet",
					"PerfectThread",
					"PerfectLib",
					"PerfectPostgreSQL",
          "PerfectNotifications",
					"SwiftCodables",
					"SAuthCodables",
					"BiqNetLib"
			]
		),
		.target(name: "BiqCollectorExe",
				dependencies: [
					"BiqCollectorLib",
					"PerfectHTTPServer",
					"PerfectCloudFormation"
			]
		),
		.testTarget(name: "BiqCollectorLibTests", dependencies: ["BiqCollectorLib"])
	]
)

import os

enum Log {
  private static let subsystem = "com.jstayton.remi"

  static let airPlay = Logger(subsystem: subsystem, category: "airplay")
  static let android = Logger(subsystem: subsystem, category: "android")
  static let app = Logger(subsystem: subsystem, category: "app")
  static let video = Logger(subsystem: subsystem, category: "video")
}

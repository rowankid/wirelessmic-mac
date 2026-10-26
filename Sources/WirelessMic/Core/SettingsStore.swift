// SettingsStore.swift
// AppSettings 的 JSON 持久化：~/Library/Application Support/WirelessMic/settings.json。
// load() 永不抛错：文件缺失 → 写入默认配置并返回；文件损坏 → 返回默认配置且不覆盖原文件。

import Foundation

struct SettingsStore {

    /// 配置文件所在目录（Application Support / WirelessMic）。
    static var settingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("WirelessMic")
    }

    static var settingsURL: URL {
        settingsDirectory.appendingPathComponent("settings.json")
    }

    /// 读配置。首次运行（文件缺失）时写入默认配置；损坏文件不覆盖原样。
    /// 另做一次性迁移：已存映射与 v6 旧默认表完全一致时，说明用户从未改过映射，
    /// 直接升级到新默认表并保存；改过的配置一律不动。
    func load() -> AppSettings {
        let url = Self.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let defaults = AppSettings.default
            try? save(defaults)
            return defaults
        }
        guard let data = try? Data(contentsOf: url),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings.default
        }
        if settings.mappings == AppSettings.legacyDefaultMappings {
            settings.mappings = AppSettings.defaultMappings
            try? save(settings)
        }
        return settings
    }

    /// 写配置：目录不存在时创建；JSON 用 prettyPrinted + sortedKeys；原子写入。
    func save(_ settings: AppSettings) throws {
        let url = Self.settingsURL
        try FileManager.default.createDirectory(
            at: Self.settingsDirectory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
    }
}

import Foundation

public enum AppVersionInfo {
    public static func displayText(infoDictionary: [String: Any]?) -> String {
        guard let shortVersion = trimmedString(
            forKey: "CFBundleShortVersionString",
            in: infoDictionary
        ) else {
            return "Version Unknown"
        }

        guard let buildNumber = trimmedString(forKey: "CFBundleVersion", in: infoDictionary) else {
            return "Version \(shortVersion)"
        }

        return "Version \(shortVersion) (\(buildNumber))"
    }

    private static func trimmedString(forKey key: String, in infoDictionary: [String: Any]?) -> String? {
        guard let value = infoDictionary?[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

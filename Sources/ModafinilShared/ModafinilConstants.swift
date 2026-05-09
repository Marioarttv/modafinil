import Foundation

public enum ModafinilConstants {
    public static let appBundleIdentifier = "com.narcotic.modafinil"
    public static let helperMachServiceName = "com.narcotic.modafinil.helper"
    public static let helperPlistName = "com.narcotic.modafinil.helper.plist"
    public static let teamIdentifier = "3LF26Z4G2R"
    public static let appSigningRequirement = """
    anchor apple generic and identifier "\(appBundleIdentifier)" and certificate leaf[subject.OU] = "\(teamIdentifier)"
    """
}

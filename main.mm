#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <ApplicationServices/ApplicationServices.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace fs = std::filesystem;

static constexpr const char* kServiceName = "IOSCheck.AppleAccount";

struct AccountRecord {
    std::string alias;
    std::string appleId;
};

static fs::path ConfigDirectory() {
    if (const char* overrideDir = std::getenv("IOSCHECK_HOME"); overrideDir != nullptr && *overrideDir != '\0') {
        return fs::path(overrideDir);
    }

    NSString* appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (appSupport != nil) {
        return fs::path(appSupport.fileSystemRepresentation) / "IOSCheck";
    }

    return fs::current_path() / ".ioscheck";
}

static fs::path ConfigPath() {
    return ConfigDirectory() / "accounts.txt";
}

static std::string Trim(std::string value) {
    const auto begin = value.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) {
        return {};
    }

    const auto end = value.find_last_not_of(" \t\r\n");
    return value.substr(begin, end - begin + 1);
}

static std::vector<std::string> Split(std::string_view text, char delimiter) {
    std::vector<std::string> parts;
    std::string current;
    for (char ch : text) {
        if (ch == delimiter) {
            parts.push_back(current);
            current.clear();
        } else {
            current.push_back(ch);
        }
    }
    parts.push_back(current);
    return parts;
}

static NSString* ToNSString(const std::string& value) {
    return [[NSString alloc] initWithUTF8String:value.c_str()];
}

static std::string FromNSString(NSString* value) {
    return value == nil ? std::string() : std::string(value.UTF8String);
}

static bool EnsureConfigDirectory(std::string* errorMessage) {
    std::error_code ec;
    fs::create_directories(ConfigDirectory(), ec);
    if (ec) {
        if (errorMessage != nullptr) {
            *errorMessage = "无法创建配置目录: " + ConfigDirectory().string();
        }
        return false;
    }

    fs::permissions(
        ConfigDirectory(),
        fs::perms::owner_all,
        fs::perm_options::replace,
        ec
    );
    return true;
}

static std::vector<AccountRecord> LoadAccounts() {
    std::vector<AccountRecord> accounts;
    std::ifstream input(ConfigPath());
    std::string line;

    while (std::getline(input, line)) {
        line = Trim(line);
        if (line.empty() || line.starts_with('#')) {
            continue;
        }

        auto parts = Split(line, '|');
        if (parts.size() < 2) {
            continue;
        }

        AccountRecord record;
        record.alias = Trim(parts[0]);
        record.appleId = Trim(parts[1]);
        if (!record.alias.empty() && !record.appleId.empty()) {
            accounts.push_back(record);
        }
    }

    return accounts;
}

static bool SaveAccounts(const std::vector<AccountRecord>& accounts, std::string* errorMessage) {
    if (!EnsureConfigDirectory(errorMessage)) {
        return false;
    }

    std::ofstream output(ConfigPath(), std::ios::trunc);
    if (!output) {
        if (errorMessage != nullptr) {
            *errorMessage = "无法写入配置文件: " + ConfigPath().string();
        }
        return false;
    }

    output << "# alias|apple_id\n";
    for (const auto& account : accounts) {
        output << account.alias << '|' << account.appleId << '\n';
    }

    std::error_code ec;
    fs::permissions(
        ConfigPath(),
        fs::perms::owner_read | fs::perms::owner_write,
        fs::perm_options::replace,
        ec
    );

    return true;
}

static std::optional<std::size_t> FindAccountIndex(const std::vector<AccountRecord>& accounts, std::string_view alias) {
    for (std::size_t i = 0; i < accounts.size(); ++i) {
        if (accounts[i].alias == alias) {
            return i;
        }
    }
    return std::nullopt;
}

static bool StorePassword(const AccountRecord& account, const std::string& password, std::string* errorMessage) {
    NSData* passwordData = [NSData dataWithBytes:password.data() length:password.size()];
    NSDictionary* baseQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: [NSString stringWithUTF8String:kServiceName],
        (__bridge id)kSecAttrAccount: ToNSString(account.alias),
    };

    NSMutableDictionary* addQuery = [baseQuery mutableCopy];
    addQuery[(__bridge id)kSecAttrLabel] = ToNSString(account.appleId);
    addQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    addQuery[(__bridge id)kSecValueData] = passwordData;

    OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)addQuery, nullptr);
    if (addStatus == errSecDuplicateItem) {
        NSDictionary* updateData = @{
            (__bridge id)kSecAttrLabel: ToNSString(account.appleId),
            (__bridge id)kSecValueData: passwordData
        };
        const OSStatus updateStatus = SecItemUpdate((__bridge CFDictionaryRef)baseQuery, (__bridge CFDictionaryRef)updateData);
        if (updateStatus == errSecSuccess) {
            return true;
        }
        if (errorMessage != nullptr) {
            *errorMessage = "写入钥匙串失败，错误码: " + std::to_string(updateStatus);
        }
        return false;
    }

    if (addStatus != errSecSuccess) {
        if (errorMessage != nullptr) {
            *errorMessage = "写入钥匙串失败，错误码: " + std::to_string(addStatus);
        }
        return false;
    }

    return true;
}

static std::optional<std::string> ReadPassword(const std::string& alias) {
    NSDictionary* query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: [NSString stringWithUTF8String:kServiceName],
        (__bridge id)kSecAttrAccount: ToNSString(alias),
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef result = nullptr;
    const OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == nullptr) {
        return std::nullopt;
    }

    NSData* data = (__bridge_transfer NSData*)result;
    return std::string(static_cast<const char*>(data.bytes), data.length);
}

static bool DeletePassword(const std::string& alias) {
    NSDictionary* query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: [NSString stringWithUTF8String:kServiceName],
        (__bridge id)kSecAttrAccount: ToNSString(alias)
    };
    const OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess || status == errSecItemNotFound;
}

static bool DeleteAllPasswords(const std::vector<AccountRecord>& accounts) {
    bool allSucceeded = true;
    for (const auto& account : accounts) {
        if (!DeletePassword(account.alias)) {
            allSucceeded = false;
        }
    }
    return allSucceeded;
}

static bool ClearLocalAccounts(std::string* errorMessage) {
    std::error_code ec;
    fs::remove(ConfigPath(), ec);
    if (ec) {
        if (errorMessage != nullptr) {
            *errorMessage = "无法删除配置文件: " + ConfigPath().string();
        }
        return false;
    }
    return true;
}

static void CopyToPasteboard(NSString* text) {
    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:text forType:NSPasteboardTypeString];
}

static void CopySensitiveToPasteboard(NSString* text) {
    CopyToPasteboard(text);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
            NSString* current = [pasteboard stringForType:NSPasteboardTypeString];
            if ([current isEqualToString:text]) {
                [pasteboard clearContents];
            }
        }
    );
}

static bool HasAccessibilityPermission() {
    return AXIsProcessTrusted();
}

static void PromptAccessibilityPermission() {
    NSDictionary* options = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

static void SendPasteShortcut() {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == nullptr) {
        return;
    }

    CGEventRef keyDown = CGEventCreateKeyboardEvent(source, static_cast<CGKeyCode>(9), true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(source, static_cast<CGKeyCode>(9), false);
    if (keyDown != nullptr && keyUp != nullptr) {
        CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
        CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);
        CGEventPost(kCGAnnotatedSessionEventTap, keyDown);
        CGEventPost(kCGAnnotatedSessionEventTap, keyUp);
    }

    if (keyDown != nullptr) {
        CFRelease(keyDown);
    }
    if (keyUp != nullptr) {
        CFRelease(keyUp);
    }
    CFRelease(source);
}

static void TypeTextString(NSString* text) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == nullptr) {
        return;
    }

    for (NSUInteger i = 0; i < text.length; ++i) {
        UniChar character = [text characterAtIndex:i];
        CGEventRef keyDown = CGEventCreateKeyboardEvent(source, 0, true);
        CGEventRef keyUp = CGEventCreateKeyboardEvent(source, 0, false);
        if (keyDown != nullptr && keyUp != nullptr) {
            CGEventKeyboardSetUnicodeString(keyDown, 1, &character);
            CGEventKeyboardSetUnicodeString(keyUp, 1, &character);
            CGEventPost(kCGAnnotatedSessionEventTap, keyDown);
            CGEventPost(kCGAnnotatedSessionEventTap, keyUp);
        }
        if (keyDown != nullptr) {
            CFRelease(keyDown);
        }
        if (keyUp != nullptr) {
            CFRelease(keyUp);
        }
        usleep(12000);
    }

    CFRelease(source);
}

static void PasteAfterDelay(NSString* text, NSTimeInterval delaySeconds, bool sensitive) {
    if (sensitive) {
        CopySensitiveToPasteboard(text);
    } else {
        CopyToPasteboard(text);
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delaySeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            SendPasteShortcut();
        }
    );
}

static void TypeAfterDelay(NSString* text, NSTimeInterval delaySeconds) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delaySeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            TypeTextString(text);
        }
    );
}

static void OpenURLString(NSString* urlString) {
    NSURL* url = [NSURL URLWithString:urlString];
    if (url != nil) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

static void OpenICloudSettings() {
    OpenURLString(@"x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane");
}

static void OpenAppStoreSettings() {
    OpenURLString(@"macappstore://");
}

static NSString* EscapeSingleQuotes(NSString* input) {
    return [input stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
}

static NSString* MountedIOSCheckVolumePath() {
    NSArray<NSURL*>* mounted = [[NSFileManager defaultManager] mountedVolumeURLsIncludingResourceValuesForKeys:nil options:0];
    for (NSURL* url in mounted.reverseObjectEnumerator) {
        NSString* path = url.path;
        NSString* candidate = [path stringByAppendingPathComponent:@"IOSCheck.app"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            return path;
        }
    }
    return nil;
}

static NSString* LaunchInstalledCommand() {
    return @"xattr -dr com.apple.quarantine /Applications/IOSCheck.app && open /Applications/IOSCheck.app";
}

static NSString* InstallAndLaunchCommand() {
    NSString* volumePath = MountedIOSCheckVolumePath();
    if (volumePath == nil) {
        volumePath = @"/Volumes/IOSCheck";
    }

    NSString* escapedVolume = EscapeSingleQuotes(volumePath);
    return [NSString stringWithFormat:
        @"cp -R '%@/IOSCheck.app' /Applications/ && xattr -dr com.apple.quarantine /Applications/IOSCheck.app && open /Applications/IOSCheck.app",
        escapedVolume
    ];
}

static NSAlert* MakeAlert(NSString* title, NSString* info, NSAlertStyle style) {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = info;
    alert.alertStyle = style;
    return alert;
}

static NSString* BuildGuideText(const AccountRecord& account, const std::optional<std::string>& password) {
    std::ostringstream builder;
    builder << "别名: " << account.alias << "\n";
    builder << "Apple ID: " << account.appleId << "\n";

    builder
        << "\n安全边界:\n"
        << "1. 本工具只管理本地资料和钥匙串密码。\n"
        << "2. 无法自动退出当前 iCloud 或 App Store 账号。\n"
        << "3. 无法直接接管苹果受保护的系统登录流程。\n"
        << "\n建议步骤:\n"
        << "1. 点击下方“登录到 iCloud”或“登录到 App Store”。\n"
        << "2. 程序会打开对应位置，并辅助填入账号。\n"
        << "3. 如有需要，请你自己确认退出当前账号。\n"
        << "4. 再由你完成最终登录确认。\n";

    if (password.has_value()) {
        builder << "5. 密码可通过自动输入或复制方式补全。\n";
    } else {
        builder << "5. 未在钥匙串中找到对应密码。\n";
    }

    return ToNSString(builder.str());
}

@interface AccountEditorController : NSWindowController
- (instancetype)initWithAccount:(const AccountRecord*)account
                       password:(NSString*)password
                     completion:(void (^)(BOOL confirmed, AccountRecord record, NSString* password))completion;
@end

@interface AccountEditorController ()
@property(nonatomic, copy) void (^completion)(BOOL confirmed, AccountRecord record, NSString* password);
@property(nonatomic, strong) NSTextField* aliasField;
@property(nonatomic, strong) NSTextField* appleIdField;
@property(nonatomic, strong) NSSecureTextField* passwordField;
@end

@implementation AccountEditorController

- (instancetype)initWithAccount:(const AccountRecord*)account
                       password:(NSString*)password
                     completion:(void (^)(BOOL confirmed, AccountRecord record, NSString* password))completion {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 214)
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self = [super initWithWindow:window];
    if (!self) {
        return nil;
    }

    self.completion = completion;
    window.title = account == nullptr ? @"新增账号" : @"编辑账号";
    window.releasedWhenClosed = NO;
    [window center];

    NSView* content = window.contentView;
    NSArray<NSString*>* labels = @[ @"别名", @"Apple ID", @"密码" ];
    NSMutableArray<NSTextField*>* fields = [NSMutableArray array];

    for (NSInteger i = 0; i < labels.count; ++i) {
        NSTextField* label = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 166 - i * 46, 90, 24)];
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.editable = NO;
        label.selectable = NO;
        label.stringValue = labels[i];
        [content addSubview:label];

        NSTextField* field = i == 2
            ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(110, 162 - i * 46, 280, 28)]
            : [[NSTextField alloc] initWithFrame:NSMakeRect(110, 162 - i * 46, 280, 28)];
        [content addSubview:field];
        [fields addObject:field];
    }

    self.aliasField = fields[0];
    self.appleIdField = fields[1];
    self.passwordField = (NSSecureTextField*)fields[2];

    if (account != nullptr) {
        self.aliasField.stringValue = ToNSString(account->alias);
        self.appleIdField.stringValue = ToNSString(account->appleId);
        if (password != nil) {
            self.passwordField.stringValue = password;
        }
    }

    NSButton* saveButton = [[NSButton alloc] initWithFrame:NSMakeRect(260, 20, 80, 32)];
    saveButton.title = @"保存";
    saveButton.bezelStyle = NSBezelStyleRounded;
    saveButton.target = self;
    saveButton.action = @selector(saveAction:);
    [content addSubview:saveButton];

    NSButton* cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(350, 20, 80, 32)];
    cancelButton.title = @"取消";
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.target = self;
    cancelButton.action = @selector(cancelAction:);
    [content addSubview:cancelButton];

    return self;
}

- (void)saveAction:(id)sender {
    AccountRecord record;
    record.alias = Trim(FromNSString(self.aliasField.stringValue));
    record.appleId = Trim(FromNSString(self.appleIdField.stringValue));
    NSString* password = self.passwordField.stringValue;

    if (record.alias.empty() || record.appleId.empty() || password.length == 0) {
        [MakeAlert(@"信息不完整", @"别名、Apple ID 和密码不能为空。", NSAlertStyleWarning) runModal];
        return;
    }

    if (self.completion) {
        self.completion(YES, record, password);
    }
    [self close];
}

- (void)cancelAction:(id)sender {
    if (self.completion) {
        AccountRecord empty;
        self.completion(NO, empty, nil);
    }
    [self close];
}

@end

@interface AppController : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate>
@end

@interface AppController ()
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSTableView* tableView;
@property(nonatomic, strong) NSTextField* detailLabel;
@property(nonatomic, strong) NSMutableArray<NSDictionary*>* accounts;
@property(nonatomic, strong) AccountEditorController* editor;
@property(nonatomic, strong) NSTextField* statusLabel;
@property(nonatomic, strong) NSButton* loginICloudButton;
@property(nonatomic, strong) NSButton* loginAppStoreButton;
@property(nonatomic, strong) NSButton* launchCommandButton;
@end

@implementation AppController

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    [self loadAccounts];
    [self buildWindow];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 780, 460)
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"IOSCheck";
    self.window.minSize = NSMakeSize(760, 440);
    [self.window center];

    NSView* content = self.window.contentView;

    NSTextField* title = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 414, 280, 28)];
    title.bezeled = NO;
    title.drawsBackground = NO;
    title.editable = NO;
    title.selectable = NO;
    title.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
    title.stringValue = @"Apple 账号切换助手";
    [content addSubview:title];

    NSTextField* subtitle = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 390, 620, 18)];
    subtitle.bezeled = NO;
    subtitle.drawsBackground = NO;
    subtitle.editable = NO;
    subtitle.selectable = NO;
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.stringValue = @"账号信息保存在本地文件，密码仅保存在 macOS 钥匙串。";
    [content addSubview:subtitle];

    NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 132, 320, 240)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;

    self.tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    NSTableColumn* aliasColumn = [[NSTableColumn alloc] initWithIdentifier:@"alias"];
    aliasColumn.title = @"别名";
    aliasColumn.width = 110;
    [self.tableView addTableColumn:aliasColumn];

    NSTableColumn* appleIdColumn = [[NSTableColumn alloc] initWithIdentifier:@"appleId"];
    appleIdColumn.title = @"Apple ID";
    appleIdColumn.width = 190;
    [self.tableView addTableColumn:appleIdColumn];

    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    scrollView.documentView = self.tableView;
    [content addSubview:scrollView];

    NSBox* panel = [[NSBox alloc] initWithFrame:NSMakeRect(360, 132, 400, 240)];
    panel.title = @"切换提示";
    [content addSubview:panel];

    self.detailLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(378, 162, 364, 190)];
    self.detailLabel.bezeled = NO;
    self.detailLabel.drawsBackground = NO;
    self.detailLabel.editable = NO;
    self.detailLabel.selectable = YES;
    self.detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.detailLabel.usesSingleLineMode = NO;
    self.detailLabel.stringValue = @"选择左侧账号后，这里会显示切换提示。";
    [content addSubview:self.detailLabel];

    self.loginICloudButton = [[NSButton alloc] initWithFrame:NSMakeRect(378, 108, 174, 34)];
    self.loginICloudButton.title = @"登录到 iCloud";
    self.loginICloudButton.bezelStyle = NSBezelStyleRounded;
    self.loginICloudButton.target = self;
    self.loginICloudButton.action = @selector(loginToICloud:);
    self.loginICloudButton.enabled = NO;
    [content addSubview:self.loginICloudButton];

    self.loginAppStoreButton = [[NSButton alloc] initWithFrame:NSMakeRect(568, 108, 174, 34)];
    self.loginAppStoreButton.title = @"登录到 App Store";
    self.loginAppStoreButton.bezelStyle = NSBezelStyleRounded;
    self.loginAppStoreButton.target = self;
    self.loginAppStoreButton.action = @selector(loginToAppStore:);
    self.loginAppStoreButton.enabled = NO;
    [content addSubview:self.loginAppStoreButton];

    self.launchCommandButton = [[NSButton alloc] initWithFrame:NSMakeRect(378, 68, 364, 30)];
    self.launchCommandButton.title = @"复制启动命令";
    self.launchCommandButton.bezelStyle = NSBezelStyleRounded;
    self.launchCommandButton.target = self;
    self.launchCommandButton.action = @selector(copyLaunchCommand:);
    [content addSubview:self.launchCommandButton];

    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 40, 740, 18)];
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.selectable = NO;
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.stringValue = @"选择账号后，可直接打开 iCloud 或 App Store，再辅助填充账号和密码。";
    [content addSubview:self.statusLabel];

    NSArray<NSDictionary*>* buttons = @[
        @{@"title": @"新增", @"selector": NSStringFromSelector(@selector(addAccount:)), @"x": @20, @"y": @18, @"w": @72},
        @{@"title": @"编辑", @"selector": NSStringFromSelector(@selector(editAccount:)), @"x": @100, @"y": @18, @"w": @72},
        @{@"title": @"删除", @"selector": NSStringFromSelector(@selector(deleteAccount:)), @"x": @180, @"y": @18, @"w": @72},
        @{@"title": @"复制 Apple ID", @"selector": NSStringFromSelector(@selector(copyAppleId:)), @"x": @260, @"y": @18, @"w": @116},
        @{@"title": @"复制密码", @"selector": NSStringFromSelector(@selector(copyPassword:)), @"x": @384, @"y": @18, @"w": @96},
        @{@"title": @"显示指引", @"selector": NSStringFromSelector(@selector(showGuide:)), @"x": @488, @"y": @18, @"w": @86},
        @{@"title": @"自动填 Apple ID", @"selector": NSStringFromSelector(@selector(autoPasteAppleId:)), @"x": @582, @"y": @18, @"w": @154},
        @{@"title": @"清空本地账号", @"selector": NSStringFromSelector(@selector(clearLocalAccountsAction:)), @"x": @20, @"y": @58, @"w": @120},
        @{@"title": @"清空钥匙串密码", @"selector": NSStringFromSelector(@selector(clearKeychainPasswordsAction:)), @"x": @148, @"y": @58, @"w": @138}
    ];

    for (NSDictionary* config in buttons) {
        NSButton* button = [[NSButton alloc] initWithFrame:NSMakeRect([config[@"x"] doubleValue], [config[@"y"] doubleValue], [config[@"w"] doubleValue], 34)];
        button.title = config[@"title"];
        button.bezelStyle = NSBezelStyleRounded;
        button.target = self;
        button.action = NSSelectorFromString(config[@"selector"]);
        [content addSubview:button];
    }
}

- (void)loadAccounts {
    self.accounts = [NSMutableArray array];
    for (const auto& account : LoadAccounts()) {
        [self.accounts addObject:@{
            @"alias": ToNSString(account.alias),
            @"appleId": ToNSString(account.appleId)
        }];
    }
}

- (std::optional<AccountRecord>)selectedAccount {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= self.accounts.count) {
        return std::nullopt;
    }

    NSDictionary* item = self.accounts[row];
    AccountRecord record;
    record.alias = FromNSString(item[@"alias"]);
    record.appleId = FromNSString(item[@"appleId"]);
    return record;
}

- (void)refreshAfterPersist:(const std::vector<AccountRecord>&)records {
    std::string error;
    if (!SaveAccounts(records, &error)) {
        [MakeAlert(@"保存失败", ToNSString(error), NSAlertStyleCritical) runModal];
        return;
    }

    [self loadAccounts];
    [self.tableView reloadData];
    self.detailLabel.stringValue = @"操作完成，选择左侧账号查看切换提示。";
    self.loginICloudButton.enabled = NO;
    self.loginAppStoreButton.enabled = NO;
}

- (void)addAccount:(id)sender {
    __weak AppController* weakSelf = self;
    self.editor = [[AccountEditorController alloc] initWithAccount:nullptr
                                                          password:nil
                                                        completion:^(BOOL confirmed, AccountRecord record, NSString* password) {
        if (!confirmed) {
            return;
        }

        std::vector<AccountRecord> records = LoadAccounts();
        if (FindAccountIndex(records, record.alias).has_value()) {
            [MakeAlert(@"别名重复", @"请使用不同的别名。", NSAlertStyleWarning) runModal];
            return;
        }

        std::string error;
        if (!StorePassword(record, FromNSString(password), &error)) {
            [MakeAlert(@"钥匙串写入失败", ToNSString(error), NSAlertStyleCritical) runModal];
            return;
        }

        records.push_back(record);
        [weakSelf refreshAfterPersist:records];
    }];
    [self.editor showWindow:nil];
}

- (void)editAccount:(id)sender {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先从左侧列表选择一个账号。", NSAlertStyleInformational) runModal];
        return;
    }

    const auto password = ReadPassword(selected->alias);
    __weak AppController* weakSelf = self;
    self.editor = [[AccountEditorController alloc] initWithAccount:&(*selected)
                                                          password:password.has_value() ? ToNSString(*password) : nil
                                                        completion:^(BOOL confirmed, AccountRecord updated, NSString* newPassword) {
        if (!confirmed) {
            return;
        }

        std::vector<AccountRecord> records = LoadAccounts();
        const auto index = FindAccountIndex(records, selected->alias);
        if (!index.has_value()) {
            [MakeAlert(@"账号不存在", @"该账号可能已被删除，请刷新后重试。", NSAlertStyleWarning) runModal];
            return;
        }

        if (updated.alias != selected->alias) {
            const auto duplicate = FindAccountIndex(records, updated.alias);
            if (duplicate.has_value()) {
                [MakeAlert(@"别名重复", @"请使用不同的别名。", NSAlertStyleWarning) runModal];
                return;
            }
            DeletePassword(selected->alias);
        }

        std::string error;
        if (!StorePassword(updated, FromNSString(newPassword), &error)) {
            [MakeAlert(@"钥匙串写入失败", ToNSString(error), NSAlertStyleCritical) runModal];
            return;
        }

        records[*index] = updated;
        [weakSelf refreshAfterPersist:records];
    }];
    [self.editor showWindow:nil];
}

- (void)deleteAccount:(id)sender {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先从左侧列表选择一个账号。", NSAlertStyleInformational) runModal];
        return;
    }

    NSAlert* confirm = MakeAlert(@"删除账号", @"将同时删除本地账号资料和对应钥匙串密码。", NSAlertStyleWarning);
    [confirm addButtonWithTitle:@"删除"];
    [confirm addButtonWithTitle:@"取消"];
    if ([confirm runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    std::vector<AccountRecord> records = LoadAccounts();
    const auto index = FindAccountIndex(records, selected->alias);
    if (!index.has_value()) {
        return;
    }

    records.erase(records.begin() + static_cast<long>(*index));
    DeletePassword(selected->alias);
    [self refreshAfterPersist:records];
}

- (void)copyAppleId:(id)sender {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先选择一个账号。", NSAlertStyleInformational) runModal];
        return;
    }

    CopyToPasteboard(ToNSString(selected->appleId));
    [MakeAlert(@"已复制", @"Apple ID 已复制到剪贴板。", NSAlertStyleInformational) runModal];
}

- (void)copyPassword:(id)sender {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先选择一个账号。", NSAlertStyleInformational) runModal];
        return;
    }

    const auto password = ReadPassword(selected->alias);
    if (!password.has_value()) {
        [MakeAlert(@"未找到密码", @"钥匙串中没有当前账号的密码。", NSAlertStyleWarning) runModal];
        return;
    }

    CopySensitiveToPasteboard(ToNSString(*password));
    [MakeAlert(@"已复制", @"密码已复制到剪贴板，将在 60 秒后自动清空。", NSAlertStyleInformational) runModal];
}

- (void)copyLaunchCommand:(id)sender {
    NSString* command;
    NSString* message;

    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/IOSCheck.app"]) {
        command = LaunchInstalledCommand();
        message = @"已复制 Applications 版本的启动命令。";
    } else {
        command = InstallAndLaunchCommand();
        message = @"已复制从当前挂载卷安装并启动的命令。";
    }

    CopyToPasteboard(command);
    [MakeAlert(@"已复制", message, NSAlertStyleInformational) runModal];
}

- (void)clearLocalAccountsAction:(id)sender {
    NSAlert* confirm = MakeAlert(@"清空本地账号", @"将删除本机保存的账号列表，但不会删除钥匙串密码。是否继续？", NSAlertStyleWarning);
    [confirm addButtonWithTitle:@"清空"];
    [confirm addButtonWithTitle:@"取消"];
    if ([confirm runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    std::string error;
    if (!ClearLocalAccounts(&error)) {
        [MakeAlert(@"清空失败", ToNSString(error), NSAlertStyleCritical) runModal];
        return;
    }

    [self loadAccounts];
    [self.tableView reloadData];
    self.detailLabel.stringValue = @"本地账号列表已清空。";
    self.statusLabel.stringValue = @"本地账号列表已清空，钥匙串密码未删除。";
    self.loginICloudButton.enabled = NO;
    self.loginAppStoreButton.enabled = NO;
}

- (void)clearKeychainPasswordsAction:(id)sender {
    const auto accounts = LoadAccounts();
    if (accounts.empty()) {
        [MakeAlert(@"没有可清理的数据", @"当前账号列表为空。若你曾手动改过数据，可在“钥匙串访问”中搜索 IOSCheck.AppleAccount 进一步检查。", NSAlertStyleInformational) runModal];
        return;
    }

    NSAlert* confirm = MakeAlert(@"清空钥匙串密码", @"将删除当前账号列表对应的所有钥匙串密码。是否继续？", NSAlertStyleWarning);
    [confirm addButtonWithTitle:@"清空"];
    [confirm addButtonWithTitle:@"取消"];
    if ([confirm runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    if (!DeleteAllPasswords(accounts)) {
        [MakeAlert(@"部分删除失败", @"有些钥匙串条目未能删除，请在“钥匙串访问”中搜索 IOSCheck.AppleAccount 手动检查。", NSAlertStyleWarning) runModal];
        return;
    }

    self.statusLabel.stringValue = @"当前账号列表对应的钥匙串密码已清空。";
    [MakeAlert(@"已清空", @"当前账号列表对应的钥匙串密码已删除。", NSAlertStyleInformational) runModal];
}

- (BOOL)prepareForAutoPasteWithSensitive:(BOOL)sensitive {
    if (!HasAccessibilityPermission()) {
        PromptAccessibilityPermission();
        [MakeAlert(
            @"需要辅助功能权限",
            @"自动粘贴依赖 macOS 辅助功能权限。请在系统设置 -> 隐私与安全性 -> 辅助功能 中允许 IOSCheck，然后重试。",
            NSAlertStyleWarning
        ) runModal];
        self.statusLabel.stringValue = @"未获得辅助功能权限，无法执行自动粘贴。";
        return NO;
    }

    self.statusLabel.stringValue = sensitive
        ? @"3 秒后自动输入密码，请立即切换到目标输入框。"
        : @"3 秒后自动粘贴 Apple ID，请立即切换到目标输入框。";
    return YES;
}

- (BOOL)prepareForAccountAssistedLogin:(NSString*)targetName {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先选择一个账号。", NSAlertStyleInformational) runModal];
        return NO;
    }

    if (![self prepareForAutoPasteWithSensitive:NO]) {
        return NO;
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:@"即将打开%@，3 秒后自动填入 Apple ID。随后可继续自动输入密码。", targetName];
    return YES;
}

- (void)autoPasteAppleId:(id)sender {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先选择一个账号。", NSAlertStyleInformational) runModal];
        return;
    }

    if (![self prepareForAutoPasteWithSensitive:NO]) {
        return;
    }

    PasteAfterDelay(ToNSString(selected->appleId), 3.0, false);
    [MakeAlert(@"准备自动填充", @"请在 3 秒内切换到目标输入框，随后会自动执行粘贴。", NSAlertStyleInformational) runModal];
}

- (void)autoPastePassword:(id)sender {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先选择一个账号。", NSAlertStyleInformational) runModal];
        return;
    }

    const auto password = ReadPassword(selected->alias);
    if (!password.has_value()) {
        [MakeAlert(@"未找到密码", @"钥匙串中没有当前账号的密码。", NSAlertStyleWarning) runModal];
        return;
    }

    if (![self prepareForAutoPasteWithSensitive:YES]) {
        return;
    }

    TypeAfterDelay(ToNSString(*password), 3.0);
    [MakeAlert(@"准备自动填充", @"请在 3 秒内切换到目标密码输入框，随后会自动逐字输入密码。", NSAlertStyleInformational) runModal];
}

- (void)loginToICloud:(id)sender {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先选择一个账号。", NSAlertStyleInformational) runModal];
        return;
    }

    if (![self prepareForAccountAssistedLogin:@"iCloud 设置"]) {
        return;
    }

    OpenICloudSettings();
    PasteAfterDelay(ToNSString(selected->appleId), 3.0, false);
    [MakeAlert(
        @"iCloud 辅助登录",
        @"已尝试打开 iCloud 设置。3 秒后会自动填入 Apple ID。若系统要求退出当前账号，请你手动确认；进入密码框后可再点“复制密码”或使用自动输入密码。",
        NSAlertStyleInformational
    ) runModal];
}

- (void)loginToAppStore:(id)sender {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先选择一个账号。", NSAlertStyleInformational) runModal];
        return;
    }

    if (![self prepareForAccountAssistedLogin:@"App Store"]) {
        return;
    }

    OpenAppStoreSettings();
    PasteAfterDelay(ToNSString(selected->appleId), 3.0, false);
    [MakeAlert(
        @"App Store 辅助登录",
        @"已尝试打开 App Store。3 秒后会自动填入 Apple ID。若当前已有账号，退出和确认步骤仍需你手动完成；进入密码框后可再点“复制密码”或使用自动输入密码。",
        NSAlertStyleInformational
    ) runModal];
}

- (void)showGuide:(id)sender {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        [MakeAlert(@"未选择账号", @"请先选择一个账号。", NSAlertStyleInformational) runModal];
        return;
    }

    const auto password = ReadPassword(selected->alias);
    NSString* guide = BuildGuideText(*selected, password);
    self.detailLabel.stringValue = guide;
    [MakeAlert(@"切换指引", guide, NSAlertStyleInformational) runModal];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return self.accounts.count;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
    NSString* identifier = tableColumn.identifier;
    NSTableCellView* cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 28)];
        NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 4, tableColumn.width - 16, 20)];
        field.bezeled = NO;
        field.drawsBackground = NO;
        field.editable = NO;
        field.selectable = NO;
        cell.textField = field;
        [cell addSubview:field];
        cell.identifier = identifier;
    }

    cell.textField.stringValue = self.accounts[row][identifier] ?: @"";
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    auto selected = [self selectedAccount];
    if (!selected.has_value()) {
        self.detailLabel.stringValue = @"选择左侧账号后，这里会显示切换提示。";
        self.loginICloudButton.enabled = NO;
        self.loginAppStoreButton.enabled = NO;
        return;
    }

    const auto password = ReadPassword(selected->alias);
    self.detailLabel.stringValue = BuildGuideText(*selected, password);
    self.loginICloudButton.enabled = YES;
    self.loginAppStoreButton.enabled = YES;
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        NSString* iconPath = [NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"];
        if (iconPath != nil) {
            NSImage* icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
            if (icon != nil) {
                [app setApplicationIconImage:icon];
            }
        }
        AppController* controller = [[AppController alloc] init];
        app.delegate = controller;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}

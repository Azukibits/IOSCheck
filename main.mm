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
        << "2. 无法直接切换 iPhone 或 iPad 的 iCloud / App Store 账号。\n"
        << "3. 最终登录动作必须在苹果系统设置中完成。\n"
        << "\n建议步骤:\n"
        << "1. 在目标设备打开设置。\n"
        << "2. 如有需要，退出当前 iCloud 或 App Store 账号。\n"
        << "3. 使用上面的 Apple ID 登录。\n";

    if (password.has_value()) {
        builder << "4. 需要密码时请点击“复制密码”，剪贴板会在 60 秒后自动清空。\n";
    } else {
        builder << "4. 未在钥匙串中找到对应密码。\n";
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
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 430)
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"IOSCheck";
    self.window.minSize = NSMakeSize(720, 410);
    [self.window center];

    NSView* content = self.window.contentView;

    NSTextField* title = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 384, 280, 28)];
    title.bezeled = NO;
    title.drawsBackground = NO;
    title.editable = NO;
    title.selectable = NO;
    title.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
    title.stringValue = @"Apple 账号切换助手";
    [content addSubview:title];

    NSTextField* subtitle = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 360, 520, 18)];
    subtitle.bezeled = NO;
    subtitle.drawsBackground = NO;
    subtitle.editable = NO;
    subtitle.selectable = NO;
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.stringValue = @"账号信息保存在本地文件，密码仅保存在 macOS 钥匙串。";
    [content addSubview:subtitle];

    NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 90, 320, 240)];
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

    NSBox* panel = [[NSBox alloc] initWithFrame:NSMakeRect(360, 90, 380, 240)];
    panel.title = @"切换提示";
    [content addSubview:panel];

    self.detailLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(378, 118, 344, 190)];
    self.detailLabel.bezeled = NO;
    self.detailLabel.drawsBackground = NO;
    self.detailLabel.editable = NO;
    self.detailLabel.selectable = YES;
    self.detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.detailLabel.usesSingleLineMode = NO;
    self.detailLabel.stringValue = @"选择左侧账号后，这里会显示切换提示。";
    [content addSubview:self.detailLabel];

    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 62, 720, 18)];
    self.statusLabel.bezeled = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.selectable = NO;
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.stringValue = @"自动粘贴功能需要在“系统设置 -> 隐私与安全性 -> 辅助功能”中授权。";
    [content addSubview:self.statusLabel];

    NSArray<NSDictionary*>* buttons = @[
        @{@"title": @"新增", @"selector": NSStringFromSelector(@selector(addAccount:)), @"x": @20, @"y": @18, @"w": @72},
        @{@"title": @"编辑", @"selector": NSStringFromSelector(@selector(editAccount:)), @"x": @100, @"y": @18, @"w": @72},
        @{@"title": @"删除", @"selector": NSStringFromSelector(@selector(deleteAccount:)), @"x": @180, @"y": @18, @"w": @72},
        @{@"title": @"复制 Apple ID", @"selector": NSStringFromSelector(@selector(copyAppleId:)), @"x": @260, @"y": @18, @"w": @116},
        @{@"title": @"复制密码", @"selector": NSStringFromSelector(@selector(copyPassword:)), @"x": @384, @"y": @18, @"w": @96},
        @{@"title": @"显示指引", @"selector": NSStringFromSelector(@selector(showGuide:)), @"x": @488, @"y": @18, @"w": @86},
        @{@"title": @"自动填 Apple ID", @"selector": NSStringFromSelector(@selector(autoPasteAppleId:)), @"x": @582, @"y": @18, @"w": @154}
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
        return;
    }

    const auto password = ReadPassword(selected->alias);
    self.detailLabel.stringValue = BuildGuideText(*selected, password);
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        NSString* iconPath = [NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"png"];
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

// hyotan: run Linux ARM64 programs (coding agents and their tools) inside an
// iOS app process. This is the only header an app should include. Everything
// under kernel/, fs/ and asbestos/ is internal to the runtime.
//
// hyotan is derived from iSH and is licensed under the GPLv3 with the
// additional terms in LICENSE.IOS. See hyotan/README.md.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One guest process started with -[HyotanRuntime run:...].
@interface HyotanProcess : NSObject
/// Linux pid inside the guest.
@property(nonatomic, readonly) int pid;
/// Append a line (a trailing newline is added) to the process's stdin.
- (void)writeLine:(NSString *)line;
/// Close the process's stdin. Safe to call before the process has started.
- (void)closeInput;
/// Send SIGTERM to the guest process.
- (void)terminate;
/// Diagnostics: reports whether the stdin descriptor is still open.
- (void)inspectInputForTesting:(void (^)(BOOL descriptorOpen))completion;
@end

/// The embedded Linux runtime. One instance per app; the kernel state is global.
@interface HyotanRuntime : NSObject
/// Version of the runtime library, from `git describe` at build time.
+ (NSString *)version;
/// Environment passed to every guest process as KEY=VALUE strings.
/// Defaults to HOME, PATH, LANG and TERM. Set before calling -run:.
@property(nonatomic, copy) NSArray<NSString *> *environment;
/// Mount the fakefs at `root`/data as / and bind `workspace` at /workspace.
/// `completion` runs on the main queue with nil on success.
- (void)bootRoot:(NSString *)root workspace:(NSString *)workspace
      completion:(void (^)(NSString * _Nullable error))completion;
/// Start `executable` in the guest with /workspace as its working directory.
/// Callbacks run on the main queue. `output` receives complete lines.
- (HyotanProcess *)run:(NSString *)executable arguments:(NSArray<NSString *> *)arguments
                  started:(void (^)(int pid))started
                   output:(void (^)(NSString *line, BOOL standardError))output
                   exited:(void (^)(int code))exited;
/// Diagnostics: ready flag, guest task/zombie counts, managed processes, open host fds.
- (void)inspectForTesting:(void (^)(NSDictionary<NSString *, NSNumber *> *state))completion;
@end

NS_ASSUME_NONNULL_END

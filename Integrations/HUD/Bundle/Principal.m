#import <AppKit/AppKit.h>
@import HUDNativeViewABI;
#import "EngramHUDProvider-Swift.h"

static NSError *EngramFailure(NSString *message) {
    return [NSError errorWithDomain:@"EngramHUDProvider" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface EngramHUDInstance : NSObject <HUDNativeViewInstanceV1>
@property(nonatomic, strong) NSViewController *viewController;
@property(nonatomic, strong) id<HUDNativeViewContextV1> context;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *identity;
@property(nonatomic, weak) id<HUDNativeViewHostV1> host;
@property(nonatomic, strong) EngramHUDGraphController *graph;
@property(nonatomic) BOOL invalidated;
- (BOOL)current;
@end

@implementation EngramHUDInstance
- (BOOL)current {
    if (self.invalidated) return NO;
    @try { return HUDNativeContextMatchesV1(self.context, self.identity, nil); }
    @catch (NSException *exception) { return NO; }
}
- (BOOL)applySnapshot:(NSDictionary *)snapshot error:(NSError **)error {
    if (![self current]) { if (error) *error = EngramFailure(@"Instance identity is no longer current"); return NO; }
    return [self.graph admitSnapshot:snapshot error:error];
}
- (BOOL)applyAppearance:(NSDictionary *)appearance error:(NSError **)error {
    if (![self current]) { if (error) *error = EngramFailure(@"Instance identity is no longer current"); return NO; }
    return [self.graph applyNativeAppearance:appearance error:error];
}
- (void)setVisibility:(HUDNativeViewVisibilityV1)visibility {
    if (![self current]) { [self invalidate]; return; }
    [self.graph setNativeVisibility:visibility];
}
- (NSView *)preferredFocusViewForPurpose:(HUDNativePreferredFocusPurposeV1)purpose {
    if (![self current]) return nil;
    return [self.graph preferredNativeFocusViewForPurpose:purpose];
}
- (NSDictionary *)captureViewStateWithError:(NSError **)error {
    if (![self current]) { if (error) *error = EngramFailure(@"Instance identity is no longer current"); return nil; }
    return [self.graph captureNativeStateWithError:error];
}
- (void)invalidate {
    if (self.invalidated) return;
    self.invalidated = YES;
    [self.graph invalidateGraph]; self.host = nil;
}
@end

@interface EngramHUDProvider : NSObject <HUDNativeViewProviderV1>
@end
@implementation EngramHUDProvider
- (NSDictionary *)nativeViewDescriptor {
    return @{@"abiMajor": @1, @"minimumHostABIMinor": @0, @"appearanceVersion": @1,
        @"providerIdentifier": @"engram", @"views": @[
            @{@"viewIdentifier": @"projectGraph", @"snapshotSchemaIdentifier": @"io.jsflax.engram.project-graph",
              @"snapshotSchemaVersion": @1, @"stateSchemaIdentifier": @"io.jsflax.engram.project-graph-state",
              @"stateSchemaVersion": @1, @"effects": @[]} ]};
}
- (id<HUDNativeViewInstanceV1>)makeViewWithContext:(id<HUDNativeViewContextV1>)context
    initialSnapshot:(NSDictionary *)snapshot savedState:(NSDictionary *)state appearance:(NSDictionary *)appearance
    host:(id<HUDNativeViewHostV1>)host error:(NSError **)error {
    NSDictionary *identity = HUDNativeCopyContextV1(context, error);
    if (!identity) return nil;
    EngramHUDGraphController *graph = [[EngramHUDGraphController alloc] initWithIdentity:identity savedState:state error:error];
    if (!graph) return nil;
    EngramHUDInstance *instance = [EngramHUDInstance new];
    // Immutable copies preserve exact optional identity fields; the original host context is retained
    // solely for callback routing and compared to this canonical capture on every operation.
    instance.context = context;
    instance.viewController = graph;
    instance.identity = identity; instance.host = host; instance.graph = graph;
    __weak EngramHUDInstance *weakInstance = instance;
    graph.identityIsCurrent = ^BOOL { return [weakInstance current]; };
    graph.viewStateChanged = ^{
        EngramHUDInstance *current = weakInstance;
        if ([current current]) [current.host viewStateDidChangeForContext:current.context];
    };
    if (![instance applyAppearance:appearance error:error] || (snapshot && ![instance applySnapshot:snapshot error:error])) {
        [instance invalidate]; return nil;
    }
    return instance; // Still suspended. No windows, networking, timers or renderer started here.
}
@end

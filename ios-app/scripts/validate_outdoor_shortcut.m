// Host-only serialization regression check. Never linked into Tapito or its VPN extension.
// Apple does not publish the .shortcut text encoding: use the installed Shortcuts parser
// to verify the wire format without importing, running actions, or touching user workflows.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

@interface NSObject (ShortcutSerializationCheck)
- (id)initWithDefinition:(id)definition;
- (id)initWithSerializedRepresentation:(id)representation variableProvider:(id)provider parameter:(id)parameter;
- (id)containedVariables;
- (id)serializedRepresentation;
@end

static void require(BOOL valid, NSString *message) {
    if (!valid) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

/// Checks serialized text bindings against Apple's parser, including the original broken shape.
int main(int argc, const char **argv) {
    @autoreleasepool {
        require(argc == 2, @"Usage: validate_outdoor_shortcut <unsigned.shortcut>");
        require(dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_NOW) != NULL,
                @"The installed macOS Shortcuts serialization framework is unavailable");
        Class parameterClass = NSClassFromString(@"WFTextInputParameter");
        Class stateClass = NSClassFromString(@"WFVariableStringParameterState");
        require(parameterClass && stateClass, @"Shortcuts text parser classes changed; update the host check");
        require([stateClass instancesRespondToSelector:@selector(initWithSerializedRepresentation:variableProvider:parameter:)],
                @"Shortcuts text parser contract changed; update the host check");
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1]) options:0 error:&error];
        require(data != nil, error.localizedDescription);
        NSDictionary *workflow = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:&error];
        require([workflow isKindOfClass:NSDictionary.class], error.localizedDescription ?: @"Invalid workflow plist");
        NSArray *actions = workflow[@"WFWorkflowActions"];
        require(actions.count == 11, @"Unexpected workflow action count");
        // action index, parameter key, upstream action index; these are the intended data-flow edges.
        NSArray *edges = @[@[@6, @"ticket", @1], @[@8, @"receipt", @6], @[@9, @"Text", @8]];
        for (NSArray *edge in edges) {
            NSUInteger index = [edge[0] unsignedIntegerValue];
            NSString *key = edge[1];
            NSUInteger source = [edge[2] unsignedIntegerValue];
            id parameter = [[parameterClass alloc] initWithDefinition:@{@"Key": key, @"Label": key}];
            id representation = actions[index][@"WFWorkflowActionParameters"][key];
            require(representation != nil, [NSString stringWithFormat:@"Missing %@", key]);
            id state = [[stateClass alloc] initWithSerializedRepresentation:representation variableProvider:nil parameter:parameter];
            require(state != nil, [NSString stringWithFormat:@"Apple parser discarded %@", key]);
            require([[state containedVariables] count] == 1, [NSString stringWithFormat:@"%@ must contain one output variable", key]);
            NSDictionary *roundtrip = [state serializedRepresentation];
            NSDictionary *reference = roundtrip[@"Value"][@"attachmentsByRange"][@"{0, 1}"];
            require([reference[@"OutputUUID"] isEqual:actions[source][@"WFWorkflowActionParameters"][@"UUID"]],
                    [NSString stringWithFormat:@"%@ lost or changed its upstream reference", key]);
            require([roundtrip isEqual:representation], [NSString stringWithFormat:@"%@ changed on parser round trip", key]);
            // v1 used a whole-value attachment in text parameters, silently producing empty fields.
            NSDictionary *oldShape = @{@"WFSerializationType": @"WFTextTokenAttachment", @"Value": reference};
            id rejected = [[stateClass alloc] initWithSerializedRepresentation:oldShape variableProvider:nil parameter:parameter];
            require(rejected == nil, @"Parser behavior changed: reassess the v1 regression assertion");
            printf("PASS: %s preserves upstream UUID; v1 shape reproduces empty parameter\n", key.UTF8String);
        }
    }
    return 0;
}

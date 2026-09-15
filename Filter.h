#import <Foundation/Foundation.h>

// Preserve the host's row objects and ordering so its renderer owns navigation
// and diffing. A missing identity invalidates the entire filtered result.
static inline NSArray *MCFSelectRows(NSArray *rows, NSSet<NSString *> *members,
                                     BOOL (^isConversation)(id), NSString *(^identity)(id), BOOL *valid) {
    *valid=YES;
    if (!members) return rows;
    NSMutableArray *result=[NSMutableArray array];
    for (id row in rows) {
        if (!isConversation(row)) continue;
        NSString *key=identity(row);
        if (!key.length) { *valid=NO; return rows; }
        if ([members containsObject:key]) [result addObject:row];
    }
    return [result copy];
}

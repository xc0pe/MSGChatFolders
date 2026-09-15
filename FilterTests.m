#import "Filter.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        NSDictionary *a=@{@"key":@"a"}, *b=@{@"key":@"b"}, *unit=@{@"unit":@YES};
        NSArray *rows=@[unit,a,b]; BOOL valid=NO;
        BOOL (^isChat)(id)=^BOOL(id value){ NSDictionary *r=value; return !r[@"unit"]; };
        NSString *(^key)(id)=^NSString *(id value){ NSDictionary *r=value; return r[@"key"]; };
        assert(MCFSelectRows(rows,nil,isChat,key,&valid)==rows && valid);
        NSArray *selected=MCFSelectRows(rows,[NSSet setWithObject:@"b"],isChat,key,&valid);
        assert(valid && selected.count==1 && selected[0]==b && rows.count==3);
        selected=MCFSelectRows(@[b,unit,a],[NSSet setWithArray:@[@"a",@"b"]],isChat,key,&valid);
        assert(valid && selected.count==2 && selected[0]==b && selected[1]==a);
        NSArray *unknown=@[a,@{}];
        assert(MCFSelectRows(unknown,[NSSet setWithObject:@"a"],isChat,key,&valid)==unknown && !valid);
        assert(MCFSelectRows(rows,[NSSet set],isChat,key,&valid).count==0 && valid);
        NSDictionary *updated=@{@"key":@"b",@"newMessage":@YES};
        selected=MCFSelectRows(@[updated,a],[NSSet setWithObject:@"b"],isChat,key,&valid);
        assert(valid && selected.count==1 && selected[0]==updated);
        puts("PASS: All, compact filtering, ordering, identity preservation, unknown identity fallback, empty folder, updated rows");
    }
    return 0;
}

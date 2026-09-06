#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>

@interface GABRuleManagerController : PSListController <UIDocumentPickerDelegate>
@property (nonatomic, assign) NSInteger exactCount;
@property (nonatomic, assign) NSInteger suffixCount;
@end

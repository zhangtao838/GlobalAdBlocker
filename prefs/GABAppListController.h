#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>

@interface GABAppListController : PSListController <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray *apps;
@property (nonatomic, strong) NSArray *filteredApps;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, assign) BOOL isSearching;
@end

//
//  Tracking.m
//  NoodleBox
//
//  Created by Julian Wood on 11-12-26.
//  Copyright (c) 2011 Mobilesce Inc. All rights reserved.
//

#import "Tracking.h"
#import "TestFlight.h"
#import "Flurry.h"
#import "GAI.h"
#import "GAITracker.h"
#import "GAITransaction.h"
#import "EditionManager.h"
#import "NSString-Expanded.h"
#import "NSUserDefaults+StratPad.h"
#import "UAKeychainUtils+StratPad.h"
#import "AFNetworking.h"
#import "UIDevice+IdentifierAddition.h"
#import "DataManager.h"
#import "StratFile.h"
#import "GoogleConversionPing.h"
#import <CommonCrypto/CommonDigest.h>
#import "UIDevice+IdentifierAddition.h"
#import "RegistrationManager.h"

@implementation Tracking

+ (void)startup
{

    NSDictionary *plistData = [[NSBundle mainBundle] infoDictionary];
    
#if !TARGET_IPHONE_SIMULATOR

#if TESTFLIGHT
    // installs an error handler so that we can see crashes
    NSString *tfNumber = [plistData objectForKey:@"TestFlightKey"];
    [TestFlight takeOff:tfNumber];
#endif
            
    // flurry
    [Flurry setAppVersion:[[EditionManager sharedManager] versionNumber]];
    NSString *flurryAppKey = [plistData objectForKey:@"FlurryAppKey"];
    [Flurry startSession:flurryAppKey];
    
    // Google Ecommerce

    // Optional: automatically track uncaught exceptions with Google Analytics.
    [GAI sharedInstance].trackUncaughtExceptions = NO;
    // Optional: set Google Analytics dispatch interval to e.g. 20 seconds.
    [GAI sharedInstance].dispatchInterval = 20;
    // Optional: set debug to YES for extra debugging information.
    [GAI sharedInstance].debug = NO;
    
#else
    
    [GAI sharedInstance].debug = YES;

#endif
    
    // create tracker instance and make default - Google Ecommerce
    id<GAITracker> tracker = [[GAI sharedInstance] trackerWithTrackingId:[plistData objectForKey:@"UAEcommerce"]];
    [GAI sharedInstance].defaultTracker = tracker;
    [GAI sharedInstance].optOut = NO;
    
}

+ (void)trackTransaction:(NSString*)transactionIdOrNil productId:(NSString*)productId
{
    DLog(@"Tracking transaction for: %@", productId);
    [[EditionManager sharedManager] fetchProductInfo:productId
                                          completion:^(NSDictionary *productInfo) {
                                              
                                              DLog(@"Tracking transaction with productInfo: %@", productInfo);
                                              
                                              // we don't know the transaction id for an App purchase, unless it's one we've already recorded, but we do for in-app
                                              // make a transactionId if necessary
                                              NSString *transactionId = transactionIdOrNil ? transactionIdOrNil : [NSString stringWithUUID];
                                                                                            
                                              GAITransaction *transaction =
                                              [GAITransaction transactionWithId:transactionId    // (NSString) Transaction ID, should be unique.
                                                                withAffiliation:@"App Store"];   // (NSString) Affiliation
                                              
                                              // we do collect tax on sales, which is added on to the app store price; varies by country, thus simply use 0
                                              transaction.taxMicros = (int64_t)(0);              // (int64_t) Total tax (in micros)
                                              
                                              // no shipping costs
                                              transaction.shippingMicros = (int64_t)(0);         // (int64_t) Total shipping (in micros)
                                              
                                              // price from a string like 29.99
                                              id p = [productInfo objectForKey:@"price"];
                                              NSDecimalNumber *price = [p isKindOfClass:[NSString class]] ? [NSDecimalNumber decimalNumberWithString:p] : p;
                                              int64_t micros = (int64_t)[[price decimalNumberByMultiplyingBy:[NSDecimalNumber decimalNumberWithString:@"1000000"]] intValue];
                                              
                                              // use the price for revenue and priceMicros
                                              transaction.revenueMicros = micros;       // (int64_t) Total revenue (in micros); google had this as tax + price
                                              
                                              // category is App or IAP
                                              NSString *category = [[EditionManager sharedManager] isIAP:productId] ? @"IAP" : @"App";
                                              
                                              [transaction addItemWithCode:productId                        // (NSString) Product SKU
                                                                      name:[productInfo objectForKey:@"name"]      // (NSString) Product name
                                                                  category:category                         // (NSString) Product category
                                                               priceMicros:micros                           // (int64_t)  Product price (in micros)
                                                                  quantity:1];                              // (NSInteger)  Product quantity
                                              
                                              BOOL result = [[GAI sharedInstance].defaultTracker trackTransaction:transaction];
                                              
                                              if (result) {
                                                  DLog(@"Transaction %@ queued success", transactionId);
                                                  if (!transactionIdOrNil) {
                                                      // we only store this for App Purchases, where we originally had no txnId
                                                      [UAKeychainUtils putValue:transactionId forKey:keyChainEcommerceAppTxnId];
                                                  }
                                              } else {
                                                  WLog(@"Couldn't track transaction.");
                                              }
                                              
                                          }];
    
}

+(void)trackMarketingConversion
{
    [[EditionManager sharedManager] fetchProductInfo:[[EditionManager sharedManager] baseProductId] completion:^(NSDictionary *productInfo) {
        DLog(@"Tracking google conversion ping: %@", productInfo);
        NSDictionary *plistData = [[NSBundle mainBundle] infoDictionary];
        [GoogleConversionPing pingWithConversionId:@"1064787611"
                                             label:[plistData objectForKey:@"GoogleConversionPing"]
                                             value:[productInfo objectForKey:@"price"]
                                      isRepeatable:NO idfaOnly:NO];
    }];
}

+(void)trackAdMobConversion
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:keyAdmobConversionReported]) {
        return;
    }
    
    if (![[EditionManager sharedManager] isFeatureEnabled:FeatureAdMobConversion]) {
        return;
    }
    
    // let admob know, even if this wasn't their ad conversion
    AFHTTPClient *request = [AFHTTPClient clientWithBaseURL:[NSURL URLWithString:@"http://a.admob.com"]];
    
    // params
    NSDictionary *plistData = [[NSBundle mainBundle] infoDictionary];
    NSDictionary *params = [NSDictionary dictionaryWithObjectsAndKeys:
                            [Tracking hashedISU], @"isu",
                            @"1", @"md5",
                            [plistData objectForKey:@"AdmobConversion"], @"app_id",
                            nil];
    // send request
    [request getPath:@"/f0"
          parameters:params
             success:^(AFHTTPRequestOperation *operation, id responseObject) {
                 NSString *r = [[NSString alloc] initWithData:(NSData*)responseObject encoding:NSUTF8StringEncoding];
                 if ([r length] > 0) {
                     DLog(@"App download successfully reported to AdMob: %@", r);
                     [defaults setBool:YES forKey:keyAdmobConversionReported];                     
                 }
                 [r release];
             }
             failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                 ELog(@"Couldn't record admob conversion: %@", error);
             }];
    
}

+ (NSString *)hashedISU {
    NSString *result = nil;
    NSString *isu = [[UIDevice currentDevice] uniqueDeviceIdentifier];
    
    if(isu) {
        unsigned char digest[16];
        NSData *data = [isu dataUsingEncoding:NSASCIIStringEncoding];
        CC_MD5([data bytes], [data length], digest);
        
        result = [NSString stringWithFormat: @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                  digest[0], digest[1],
                  digest[2], digest[3],
                  digest[4], digest[5],
                  digest[6], digest[7],
                  digest[8], digest[9],
                  digest[10], digest[11],
                  digest[12], digest[13],
                  digest[14], digest[15]];
        result = [result uppercaseString];
    }
    return result;
}


+ (void)pageView:(NSString *)pageName chapter:(Chapter*)chapter pageNum:(NSUInteger)pageNum
{

#if !TARGET_IPHONE_SIMULATOR
    
#if TESTFLIGHT
    NSString *checkPoint = [NSString stringWithFormat:@"%@, Chapter %@, Page %i", [chapter.title stringByReplacingOccurrencesOfString:@"\n" withString:@" "], chapter.chapterNumber, pageNum];

    [TestFlight passCheckpoint:checkPoint];
#endif
    
    // log all pages under a single event, with multiple descriptions
    [Flurry logEvent:kTrackingEventPageView withParameters:[NSDictionary dictionaryWithObjectsAndKeys:
                                                            pageName, @"pageName",
                                                            chapter.chapterNumber, @"chapterNumber",
                                                            [NSString stringWithFormat:@"%u", pageNum], @"pageNumber",
                                                            nil]];
            
#endif
    
}

+ (void)logEvent:(NSString*)eventName
{
#if !TARGET_IPHONE_SIMULATOR
    [Flurry logEvent:eventName];
#endif
}

+ (void)logEvent:(NSString*)eventName withParameters:(NSDictionary *)parameters
{
    
#if !TARGET_IPHONE_SIMULATOR
    [Flurry logEvent:eventName withParameters:parameters];
#endif
    
}

+ (void)trackUsage
{
    // curl -d "stratpadId=abc&stratfileCount=4&baseEdition=Plus&effectiveEdition=Premium&hasStratBoard=True&version=1.5.3" http://localhost:8080/usage
    
    // no point in tracking if we don't have a registration yet (since we are keyed by email)
    // typical use case is that we're trying to track before the user has registered (ie they pressed later)
    NSString *email = [[NSUserDefaults standardUserDefaults] stringForKey:keyEmail];
    if (email) {
        // host url
        NSDictionary *config = [[NSBundle mainBundle] infoDictionary];
        NSURL *url = [NSURL URLWithString:[config objectForKey:@"MBRegistrationServer"]];
        AFHTTPClient *request = [AFHTTPClient clientWithBaseURL:url];
        
        NSLocale *locale = [NSLocale currentLocale];
        NSString *countryCode = [locale objectForKey: NSLocaleCountryCode];
        NSString *country = [locale displayNameForKey: NSLocaleCountryCode value: countryCode];
        NSString *language = [[NSLocale preferredLanguages] objectAtIndex:0];
        NSString *osVersion = [[UIDevice currentDevice] systemVersion];
        NSString *deviceModel = [RegistrationManager modelAsString];
        
        // params
        EditionManager *edMan = [EditionManager sharedManager];
        NSUInteger ct = [DataManager countForEntity:NSStringFromClass([StratFile class]) predicateOrNil:nil];
        NSDictionary *params = [NSDictionary dictionaryWithObjectsAndKeys:
                                [[UIDevice currentDevice] uniqueDeviceIdentifier], @"stratpadId",
                                [NSNumber numberWithUnsignedInteger:ct], @"stratfileCount",
                                email ? email : @"", @"email",
                                [edMan originalProductShortName], @"baseEdition",
                                [edMan productShortName], @"effectiveEdition",
                                [edMan isFeatureEnabled:FeatureHasStratBoard] ? @"True" : @"False", @"hasStratBoard",
                                [edMan versionNumber], @"version",
                                [edMan versionNumber], @"api",
                                osVersion, @"osVersion",
                                country, @"country",
                                language, @"language",
                                deviceModel, @"deviceModel",
                                [[UIDevice currentDevice] uniqueGlobalDeviceIdentifier], @"deviceId",
                                nil];
        
        // post to server
        [request postPath:@"/153/usage"
               parameters:params
                  success:^(AFHTTPRequestOperation *operation, id responseObject) {
                      id json = [NSJSONSerialization JSONObjectWithData:responseObject options:0 error:nil];
                      DLog(@"Usage: %@", json);
                  }
                  failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                      ELog(@"Couldn't record usage: %@", error);
                  }];
    }
}

+ (void)shutdown
{
    // no-op
}

@end

NSString * const kTrackingCheckPointWebMobilesce        = @"Web Mobilesce";

NSString * const kTrackingEventAdImpression             = @"Ad Impression";
NSString * const kTrackingEventAdClick                  = @"Ad Click";
NSString * const kTrackingEventIAP                      = @"IAP";

NSString * const kTrackingEventYammerPostedFile         = @"Yammer: Posted File";
NSString * const kTrackingEventYammerUpdatedFile        = @"Yammer: Updated File";
NSString * const kTrackingEventYammerCommented          = @"Yammer: Commented on File";

NSString * const kTrackingEventRegistered               = @"Registration: Submitted form";

NSString * const kTrackingEventPageView                 = @"Page viewed.";

NSString* const kTrackingEventStratfileCreated          = @"StratFile created";
NSString* const kTrackingEventStratfileBackedUp         = @"StratFile backed up";
NSString* const kTrackingEventReportEmailed             = @"Report emailed";
NSString* const kTrackingEventStratfileEmailed          = @"StratFile emailed";
NSString* const kTrackingEventCSVEmailed                = @"CSV emailed";
NSString* const kTrackingEventDocxEmailed               = @"Docx emailed";
NSString* const kTrackingEventReportPrinted             = @"Report printed";

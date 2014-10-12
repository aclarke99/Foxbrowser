//
//  FXSyncEngine.m
//  Foxbrowser
//
//  Created by Simon Grätzer on 21.06.14.
//  Copyright (c) 2014 Simon Peter Grätzer. All rights reserved.
//

#import "FXSyncEngine.h"
#import "FXSyncStore.h"
#import "FXUserAuth.h"
#import "FXSyncItem.h"
#import "NSData+Ext.h"
#import "NSString+Base64.h"
#import "NSData+Base64.h"
#import "Reachability.h"
#import "HawkCredentials.h"

#include <libkern/OSAtomic.h>

NSString *const kFXSyncEngineErrorDomain = @"org.graetzer.fxsync.engine";

NSString *const kFXHeaderLastModified = @"X-Last-Modified";
NSString *const kFXHeaderTimestamp = @"X-Weave-Timestamp";
NSString *const kFXHeaderNextOffset = @"X-Weave-Next-Offset";
NSString *const kFXHeaderAlert = @"X-Weave-Alert";

NSString *const kFXHeaderIfModifiedSince = @"X-If-Modified-Since";
NSString *const kFXHeaderIfUnmodifiedSince = @"X-If-Unmodified-Since";

NSString *const kFXTabsCollectionKey = @"tabs";
NSString *const kFXBookmarksCollectionKey = @"bookmarks";
NSString *const kFXHistoryCollectionKey = @"history";
NSString *const kFXPasswordsCollectionKey = @"passwords";
NSString *const kFXPrefsCollectionKey = @"prefs";
NSString *const kFXFormsCollectionKey = @"forms";

NSInteger const SEVEN_DAYS = 7*24*60*60;

@implementation FXSyncEngine  {
    HawkCredentials *_credentials;
    NSDictionary *_keyBundle;
    NSDictionary *_collectionKeys;
    
    BOOL _foundClientRecord;
    NSInteger _storageVersion;
    
    int32_t _networkOpsCount;
}
@dynamic syncRunning, clientID, clientName;

- (instancetype)init {
    if (self = [super init]) {
        _reachability = [Reachability reachabilityForInternetConnection];
    }
    return self;
}

- (void)startSync {
    if (![self isSyncRunning]
        && _userAuth != nil
        && [_reachability isReachable]) {
        
        // Any of these methods will ideally call the next one
        if (_userAuth.syncInfo == nil) {
            [self _requestSyncInfo];
        } else if (_keyBundle == nil || _collectionKeys == nil) {
            [self _prepareKeys];
        } else if (!_foundClientRecord) {
            [self _loadMetarecord];
        } else if (_storageVersion == 5) {
            [self _performSync];
        } else {
            NSError *err = [NSError errorWithDomain:kFXSyncEngineErrorDomain
                                               code:kFXSyncEngineErrorUnsupportedStorageVersion
                                           userInfo:nil];
            [_delegate syncEngine:self didFailWithError:err];
        }
    }
}

/*! Get the reuired authorization credentials and the sync key */
- (void)_requestSyncInfo {
    OSAtomicIncrement32(&_networkOpsCount);
    [_userAuth requestSyncInfo:^(NSDictionary *syncInfo) {
        DLog(@"Sync Token %@", syncInfo);
        if (syncInfo[@"token"] != nil) {
            NSString *key = syncInfo[@"token"][@"key"];
            _credentials = [[HawkCredentials alloc] initWithHawkId:syncInfo[@"token"][@"id"]
                                                           withKey:[key dataUsingEncoding:NSUTF8StringEncoding]
                                                     withAlgorithm:CryptoAlgorithmSHA256];
            
            [self _prepareKeys];
        }
        OSAtomicDecrement32(&_networkOpsCount);
    }];
}

- (void)_performSync {
    if (_keyBundle != nil && _collectionKeys != nil) {
        OSAtomicIncrement32(&_networkOpsCount);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            [self _downloadChanges];
            [self _uploadChanges];
            OSAtomicDecrement32(&_networkOpsCount);
        });
    }
}

- (void)_downloadChanges {
    FXSyncStore *store = [FXSyncStore sharedInstance];
    
    // TODO load the info collection instead
    
    NSArray *cols = [FXSyncEngine collectionNames];
    for (NSString *cName in cols) {
        NSInteger max = [cName isEqualToString:kFXHistoryCollectionKey] ? 1500 : NSIntegerMax;
        
        NSTimeInterval newer = [store syncTimeForCollection:cName];
        [self _downloadChanges:cName
                     newerThan:newer
               unmodifiedSince:0
                        offset:nil
                       maximum:max];
    }
}

- (void)_downloadChanges:(NSString *)cName
                newerThan:(NSTimeInterval)newer
           unmodifiedSince:(NSTimeInterval)unmodified
                  offset:(NSString *)offset
                   maximum:(NSUInteger)limit {
    
    // Always sort by newest, we need all objects anyway, expect for history items.
    NSString *url = [NSString stringWithFormat:@"/storage/%@?newer=%.2f&"
                     "sort=newest&full=1&limit=250", cName, newer];
    NSDictionary *headers = nil;
    if (offset != nil) {
        url = [url stringByAppendingFormat:@"&offset=%@", offset];
        headers = @{kFXHeaderIfUnmodifiedSince : [NSString stringWithFormat:@"%.2f", unmodified]};
    }
    
    [self _sendRequest:url
                method:@"GET"
               headers:headers
               payload:nil
            completion:^(NSHTTPURLResponse *resp, id json, NSError *err) {
                
                if (resp.statusCode == 200
                           && [json isKindOfClass:[NSArray class]]) {
                    
                    for (NSDictionary *bso in json) {
                        [self _handleReceivedBSO:bso forCollection:cName];
                    }
                    NSString *nextOff = [resp allHeaderFields][kFXHeaderNextOffset];
                    NSTimeInterval nextMod = [[resp allHeaderFields][kFXHeaderLastModified] doubleValue];
                    
                    if ([nextOff length] > 0 && limit > [json count]) {
                        // Guard this query with nexMod, so we do not miss an insert
                        // by a different client
                        [self _downloadChanges:cName
                                     newerThan:newer
                               unmodifiedSince:nextMod
                                        offset:nextOff
                                       maximum:limit - [json count]];
                    } else {
                        if(nextMod > newer) {
                            // Check (nextMod > newer) so that we make sure
                            // that this is monotone increasing
                            [[FXSyncStore sharedInstance] setSyncTime:nextMod forCollection:cName];
                        }
                        
                        if (_delegate != nil) {
                            [_delegate syncEngine:self didLoadCollection:cName];
                        }
                    }
                } else if (resp.statusCode == 412 && [offset length] > 0) {
                    DLog(@"Concurrent modification, retry loading");
                    // Plus 500, because we are at least one recursion in
                    [self _downloadChanges:cName
                                 newerThan:newer
                           unmodifiedSince:0
                                    offset:nil maximum:limit+500];
                }
            }];
}

- (void)_uploadChanges {
    FXSyncStore *store = [FXSyncStore sharedInstance];
    NSArray *cols = [FXSyncEngine collectionNames];
    
    for (NSString *cName in cols) {
        NSTimeInterval newer = [store syncTimeForCollection:cName];
        NSArray *uploads = [store changedItemsForCollection:cName];
        
        // Not all data is forever relevant
        // If the user deletes the app, data should disappear
        NSInteger ttl = 0;
        if ([cName isEqualToString:kFXHistoryCollectionKey]
            || [cName isEqualToString:kFXTabsCollectionKey]) {
            ttl = SEVEN_DAYS*3;
        }
        
        for (FXSyncItem *item in uploads) {
            // We use the upload time for the entire collection,
            // rather than item.modified
            [self _uploadItem:item
                   timeToLive:ttl
              unmodifiedSince:newer];
        }
    }
}

- (void)_uploadItem:(FXSyncItem *)item
         timeToLive:(NSInteger)ttl
    unmodifiedSince:(NSTimeInterval)unmodified  {
    
    NSString *url = [NSString stringWithFormat:@"/storage/%@/%@", item.collection, item.syncId];
    
    NSString *payload = [self _encryptPayload:item.payload keyBundle:[self _keysForCollection:@"clients"]];
    NSMutableDictionary *json = [@{@"id":item.syncId,
                                   @"sortindex":@(item.sortindex),
                                   @"payload" : payload} mutableCopy];
    if (ttl > 0) json[@"ttl"] = @(ttl);
    
    [self _sendRequest:url
                method:@"PUT"
               headers:@{kFXHeaderIfUnmodifiedSince : [NSString stringWithFormat:@"%.2f", unmodified]}
               payload:json
            completion:^(NSHTTPURLResponse *resp, id json, NSError *err){
                if (resp.statusCode == 200) {
                    NSTimeInterval modified = [resp.allHeaderFields[kFXHeaderLastModified] doubleValue];
                    if (modified > unmodified) {
                        DLog(@"Successfully pushed: %@/%@", item.collection, item.syncId);
                        item.modified = modified;
                        [[FXSyncStore sharedInstance] saveItem:item];
                        [[FXSyncStore sharedInstance] setSyncTime:modified forCollection:item.collection];
                    }
                } else if (resp.statusCode == 412) {
                    DLog(@"Discarding outdated: %@/%@", item.collection, item.syncId);
                    // Just overwrite the local changes for now
                    [self _sendRequest:url
                                method:@"GET"
                               headers:nil
                               payload:nil
                            completion:^(NSHTTPURLResponse *resp, id bso, NSError *err) {
                                if (resp.statusCode == 200
                                    && [bso isKindOfClass:[NSDictionary class]]) {
                                    [self _handleReceivedBSO:bso forCollection:item.collection];
                                }
                            }];
                }
            }];
}

/*!
 * Load the global meta record which
 * contains information about the global storage version (it should be 5)
 * This should be queried to detect breaking updates
 */
- (void)_loadMetarecord {
    
    [self _sendRequest:@"/storage/meta/global"
                method:@"GET"
               headers:nil
               payload:nil
            completion:^(NSHTTPURLResponse *resp, id json, NSError *err){
                if (json != nil && resp.statusCode == 200) {
                    // This data should not be encrypted
                    NSData *src = [json[@"payload"] dataUsingEncoding:NSUTF8StringEncoding];
                    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:src
                                                                            options:0
                                                                              error:NULL];
                    _storageVersion = [payload[@"storageVersion"] integerValue];
                    
                    if (_storageVersion == 5) {
                        [self _updateClientRecord];
                    } else {
                        NSError *err = [NSError errorWithDomain:kFXSyncEngineErrorDomain
                                                           code:kFXSyncEngineErrorUnsupportedStorageVersion
                                                       userInfo:nil];
                        [_delegate syncEngine:self didFailWithError:err];
                    }
                }
            }];
}

/*! 
 *
 * Only supports storage version 5 
 */
- (void)_updateClientRecord {
    NSString *myID = [self clientID];
    NSString *url = [NSString stringWithFormat:@"/storage/clients/%@", myID];
    
    [self _sendRequest:url
                method:@"GET"
               headers:nil
               payload:nil
            completion:^(NSHTTPURLResponse *resp, id bso, NSError *err) {
                _foundClientRecord = NO;
                
                NSString *rawPayload;
                if (resp.statusCode == 200
                    && [bso isKindOfClass:[NSDictionary class]]
                    && (rawPayload = bso[@"payload"]) != nil) {
                    
                    NSData *decrypted = [self _decryptPayload:rawPayload keyBundle:[self _keysForCollection:@"clients"]];
                    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:decrypted
                                                                  options:0
                                                                    error:NULL];
                    
                    // Update the client record every 7 days
                    NSTimeInterval modified = [bso[@"modified"] doubleValue];
                    if ([payload[@"id"] isEqualToString:myID]
                        && modified > [[NSDate date] timeIntervalSince1970] - SEVEN_DAYS) {
                        
                        DLog(@"Found matching mobile client record");
                        _foundClientRecord = YES;
                        [self _performSync];
                    }
                }
                
                if (!_foundClientRecord) {
                    DLog(@"Did not find matching client record");
                    NSDictionary *client = @{@"id" : myID,
                                             @"name":[self clientName],
                                             @"type" : @"mobile",
                                             @"version" : @"3.0",
                                             @"protocols": @[@"1.5"]};
                    
                    NSData *plaintext = [NSJSONSerialization dataWithJSONObject:client options:0 error:NULL];
                    NSString *payload = [self _encryptPayload:plaintext keyBundle:[self _keysForCollection:@"clients"]];
                    NSDictionary *json = @{@"id":myID,
                                           @"payload" : payload,
                                           @"ttl":@(SEVEN_DAYS*3)};
                    [self _sendRequest:url
                                method:@"PUT"
                               headers:nil
                               payload:json
                            completion:^(NSHTTPURLResponse *resp, id bso, NSError *err) {
                                if (resp.statusCode == 200) {
                                    _foundClientRecord = YES;
                                    [self _performSync];
                                }
                            }];
                }
            }];
}

#pragma mark - Crypto

- (void)_handleReceivedBSO:(NSDictionary *)bso forCollection:(NSString *)cName {
    NSDictionary *keyBundle = [self _keysForCollection:cName];
    NSString *rawPayload = bso[@"payload"];
    if (rawPayload != nil) {
        NSData *decrypted = [self _decryptPayload:rawPayload keyBundle:keyBundle];
        if (decrypted == nil) {
            // TODO do some error handling
            return;
        }
        
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:decrypted
                                                                options:0 error:NULL];
        if (![bso[@"id"] isEqual:payload[@"id"]]) {
            // TODO do some error handling
            return;
        }
        
        FXSyncItem *item = [[FXSyncItem alloc] init];
        item.collection = cName;
        item.syncId = bso[@"id"];
        if ([payload[@"deleted"] boolValue]) {
            [[FXSyncStore sharedInstance] deleteItem:item];
            DLog(@"Deleting item: %@", payload);
        } else {
            item.modified = [bso[@"modified"] doubleValue];
            item.sortindex = [bso[@"sortindex"] integerValue];
            item.payload = decrypted;
            
            [[FXSyncStore sharedInstance] saveItem:item];
            DLog(@"Storing item: %@", payload);
        }
    }
}


/*! Create the keys necesary to encrypt the BSO payloads */
- (void)_prepareKeys {
    
    // _deriveKeys
    NSString *syncKey = _userAuth.syncInfo[@"syncKey"];
    if (syncKey != nil && _keyBundle == nil) {
        NSData *bundle = HKDF_SHA256(CreateDataWithHexString(syncKey),
                                     [_userAuth kwName:@"oldsync"],
                                     [NSData data], 2 * 32);
        
        _keyBundle = @{@"encKey":[bundle subdataWithRange:NSMakeRange(0, 32)],
                       @"hmacKey":[bundle subdataWithRange:NSMakeRange(32, 32)]};
        DLog(@"Key Bundle: %@", _keyBundle);
    }
    
    // _fetchCollectionKeys
    if (_collectionKeys == nil && _keyBundle != nil) {
        [self _sendRequest:@"/storage/crypto/keys"
                    method:@"GET" headers:nil payload:nil
                completion:^(NSHTTPURLResponse *resp, id bso, NSError *err) {
                    
                    NSString *rawPayload;
                    if (err != nil) {
                        [_delegate syncEngine:self didFailWithError:err];
                    } else if([bso isKindOfClass:[NSDictionary class]]
                              && (rawPayload = bso[@"payload"]) != nil) {
                        
                        NSData *decrypted = [self _decryptPayload:rawPayload keyBundle:_keyBundle];
                        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:decrypted
                                                                                options:NSJSONReadingMutableContainers
                                                                                  error:NULL];
                        // Let's put the default keybundle in there, so it is processed by the loop
                        NSMutableDictionary *cols = payload[@"collections"];
                        cols[@"default"] = payload[@"default"];
                        
                        NSMutableDictionary *keys = [NSMutableDictionary dictionaryWithCapacity:[cols count]];
                        for (NSString *key in cols) {
                            NSArray *arr = cols[key];
                            if ([arr count] == 2) {
                                keys[key] =  @{@"encKey" : [arr[0] base64DecodedData],
                                               @"hmacKey": [arr[1] base64DecodedData]};
                            }
                        }
                        _collectionKeys = keys;
                        [self _performSync];
                    }
                }];
    } else {
        [self _performSync];
    }
}

/*! Every collection could have an individual key bundle, currently not implemented in Firefox
 * Only the default key is used, but let's implement it anyway.
 */
- (NSDictionary *)_keysForCollection:(NSString *)cName {
    return _collectionKeys[cName] != nil ? _collectionKeys[cName] : _collectionKeys[@"default"];
}

// https://docs.services.mozilla.com/sync/storageformat5.html
- (NSData *)_decryptPayload:(NSString *)rawPayload keyBundle:(NSDictionary *)bundle {
    NSParameterAssert(rawPayload && bundle);
//    if (bso[@"payload"] == nil) {
//        @throw [NSException exceptionWithName:kFXSyncEngineErrorDomain
//                                       reason:@"BSO has no payload: nothing to decrypt?"
//                                     userInfo:bso];
//    }
    NSData *src = [rawPayload dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:src
                                                            options:0
                                                              error:NULL];
    if (payload[@"ciphertext"] == nil) {
        DLog(@"BSO has no ciphertext: nothing to decrypt?");
        return nil;
        // TODO error handling
//        @throw [NSException exceptionWithName:kFXSyncEngineErrorDomain
//                                       reason:@"BSO has no ciphertext: nothing to decrypt?"
//                                     userInfo:payload];
    }
    NSData *encKey = bundle[@"encKey"];
    NSData *hmacKey = bundle[@"hmacKey"];
    NSData *ciphertext = [payload[@"ciphertext"] dataUsingEncoding:NSUTF8StringEncoding];
    
    // Security check
    unsigned char hmac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, hmacKey.bytes, hmacKey.length, ciphertext.bytes, (CC_LONG)ciphertext.length, hmac);
    
    NSString *computedHMAC = [[NSData dataWithBytes:hmac length:CC_SHA256_DIGEST_LENGTH] hexadecimalString];
    if (![computedHMAC isEqualToString:payload[@"hmac"]]) {
        NSError *err = [NSError errorWithDomain:kFXSyncEngineErrorDomain
                                           code:kFXSyncEngineErrorEncryption
                                       userInfo:nil];
        [_delegate syncEngine:self didFailWithError:err];
        return nil;
    }
    
    NSData *IV = [payload[@"IV"] base64DecodedData];
    ciphertext = [payload[@"ciphertext"] base64DecodedData];
    
    NSData *decrypted = nil;
    size_t bufferSize = [ciphertext length];
    void *buffer = calloc(bufferSize, sizeof(uint8_t));
    if (buffer != nil) {
        size_t dataOutMoved = 0;
        BOOL padding = YES;
        CCCryptorStatus cryptStatus = CCCrypt(kCCDecrypt,
                                              kCCAlgorithmAES,
                                              padding ? kCCOptionPKCS7Padding : 0,
                                              [encKey bytes],
                                              kCCKeySizeAES256,
                                              [IV bytes],
                                              [ciphertext bytes],
                                              [ciphertext length],
                                              buffer,
                                              bufferSize,
                                              &dataOutMoved);
        
        if (cryptStatus == kCCSuccess) {
            decrypted = [NSData dataWithBytesNoCopy:buffer length: dataOutMoved freeWhenDone: YES];
        } else {
            free(buffer);
        }
    }

    return decrypted;
}

- (NSString *)_encryptPayload:(NSData *)plaintext keyBundle:(NSDictionary *)bundle {
    NSParameterAssert(plaintext && bundle);

    NSData *encKey = bundle[@"encKey"];
    NSData *hmacKey = bundle[@"hmacKey"];
    // AES blocksize is always 128 bit
    NSData *IV = [RandomString(16) dataUsingEncoding:NSUTF8StringEncoding];
    
    NSData *ciphertext = nil;
    size_t bufferSize = [plaintext length] + [encKey length];
    void *buffer = calloc(bufferSize, sizeof(uint8_t));
    if (buffer != nil) {
        size_t dataOutMoved = 0;
        BOOL padding = YES;
        CCCryptorStatus cryptStatus = CCCrypt(kCCEncrypt,
                                              kCCAlgorithmAES,
                                              padding ? kCCOptionPKCS7Padding : 0,
                                              [encKey bytes],
                                              kCCKeySizeAES256,
                                              [IV bytes],
                                              [plaintext bytes],
                                              [plaintext length],
                                              buffer,
                                              bufferSize,
                                              &dataOutMoved);
        
        if (cryptStatus == kCCSuccess) {
            ciphertext = [NSData dataWithBytesNoCopy:buffer length: dataOutMoved freeWhenDone: YES];
        } else {
            free(buffer);
        }
    }
    if (ciphertext != nil) {
        NSString *ciphertextString = [ciphertext base64EncodedString];
        
        // Ciphertext is calculated from the base64 encoded string
        ciphertext = [ciphertextString dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char hmac[CC_SHA256_DIGEST_LENGTH];
        CCHmac(kCCHmacAlgSHA256, hmacKey.bytes, hmacKey.length, ciphertext.bytes, (CC_LONG)ciphertext.length, hmac);
        NSString *computedHMAC = [[NSData dataWithBytes:hmac length:CC_SHA256_DIGEST_LENGTH] hexadecimalString];
        
        NSDictionary *payload = @{@"IV" : [IV base64EncodedString],
                                  @"hmac" : computedHMAC,
                                  @"ciphertext" : ciphertextString};
        
        NSData *jsonPayload = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
        return [[NSString alloc] initWithData:jsonPayload encoding:NSUTF8StringEncoding];
    }
    return nil;
}


#pragma mark - Helper Methods

- (void)_sendRequest:(NSString *)path
              method:(NSString *)method
             headers:(NSDictionary *)headers
             payload:(NSDictionary *)json
          completion:(void (^)(NSHTTPURLResponse *resp, id, NSError *))completion {
    
    NSString *base = _userAuth.syncInfo[@"token"][@"api_endpoint"];
    NSString *url = [NSString stringWithFormat:@"%@%@", base, path];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:kFXConnectionTimeout];
    request.HTTPMethod = method;
    for (NSString *key in headers) {
        [request setValue:headers[key] forHTTPHeaderField:key];
    }
    if (json != nil) {
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:json
                                                           options:0
                                                             error:NULL];
    } else {
        // For some reason a genius at mozilla decided that even a GET request without body content needs to
        // have a hash for the body in it's hawk auth (but of course just on the sync service and nowhere else)
        request.HTTPBody = [NSData data];
    }
    OSAtomicIncrement32(&_networkOpsCount);
    [_userAuth sendHawkRequest:request credentials:_credentials completion:^(NSHTTPURLResponse *resp, id json, NSError *err) {
        BOOL cntn = [self _handleSpecialResponses:resp];
        
        if (cntn && completion) {
            completion(resp, json, err);
        }
        OSAtomicDecrement32(&_networkOpsCount);
    }];
}

/*! Handle Alerts, Backoff, timestamp + offset calculations */
- (BOOL)_handleSpecialResponses:(NSHTTPURLResponse *)headers {
    return YES;
}

+ (NSArray *)collectionNames {
    return @[kFXTabsCollectionKey, kFXBookmarksCollectionKey,
             kFXHistoryCollectionKey];
    // , kFXPasswordsCollectionKey, kFXFormsCollectionKey
}

- (BOOL)isSyncRunning {
    return _networkOpsCount > 0;
}

- (NSString *)clientID {
    NSUUID *uuid = [UIDevice currentDevice].identifierForVendor;
    NSString *myID = [uuid UUIDString];
    return [myID substringWithRange:NSMakeRange([myID length] - 13, 12)];
}

- (NSString *)clientName {
    NSString *name = [[UIDevice currentDevice] name];
    if (!name.length) name = @"iOS Foxbrowser";
    
    return name;
}

@end
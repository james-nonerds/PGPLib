//
//  NetPGP.m
//  PGP Demo
//
//  Created by James Knight on 6/9/15.
//  Copyright (c) 2015 Gradient. All rights reserved.
//

#import "netpgp.h"
#import "PGP.h"

#pragma mark - Constants

#define DEFAULT_HASH_ALG "SHA256"
#define DEFAULT_MEMORY_SIZE "4194304"
#define DEFAULT_BIT_COUNT 1024
#define DEFAULT_KEY_TYPE 1

#define SHOULD_ARMOR 1
#define CLEARTEXT 0

NSString *const PGPOptionKeyType = @"keyType";
NSString *const PGPOptionNumBits = @"numBits";
NSString *const PGPOptionUserId = @"userId";
NSString *const PGPOptionUnlocked = @"unlocked";

NSString *const PGPPubringFilename = @"pubring.gpg";
NSString *const PGPSecringFilename = @"secring.gpg";

static NSString *const PGPDefaultUsername = @"default-user";


#pragma mark - PGP extension


@interface PGP () {
    NSString *_homedir, *_pubringPath, *_secringPath, *_outPath;
}

@property (nonatomic, readonly) netpgp_t *netpgp;

@property (nonatomic, readonly) NSUUID *uuid;
@property (nonatomic, readonly) NSString *outPath;

@property (nonatomic, readonly) NSString *homedir;
@property (nonatomic, readonly) NSString *pubringPath;
@property (nonatomic, readonly) NSString *secringPath;

@property (nonatomic, strong) NSString *userId;

+ (instancetype)pgp;
+ (NSError *)errorWithCause:(NSString *)cause;

- (BOOL)initNetPGPForMode:(PGPMode)mode;

- (NSString *)readPubringWithError:(NSError **)error;
- (NSString *)readSecringWithError:(NSError **)error;

- (void)writeSecringWithArmoredKey:(NSString *)armoredKey error:(NSError **)error;

@end


#pragma mark - PGP implementation


@implementation PGP


#pragma mark Constructors


+ (instancetype)keyGenerator {
    PGP *pgp = [self pgp];
    
    return [pgp initNetPGPForMode:PGPModeGenerate] ? pgp : nil;
}


+ (instancetype)decryptorWithPrivateKey:(NSString *)armoredPrivateKey {
    PGP *pgp = [self pgp];
    
    NSError *error;
    [pgp writeSecringWithArmoredKey:armoredPrivateKey error:&error];
    
    if (error) {
        NSLog(@"Error writing armored key: %@", error);
        return nil;
    }
    
    return [pgp initNetPGPForMode:PGPModeDecrypt] ? pgp : nil;
}


+ (instancetype)encryptor {
    PGP *pgp = [self pgp];
    return [pgp initNetPGPForMode:PGPModeEncrypt] ? pgp : nil;
}


+ (instancetype)signerWithPrivateKey:(NSString *)privateKey {
    PGP *pgp = [self pgp];
    
    NSError *error;
    [pgp writeSecringWithArmoredKey:privateKey error:&error];
    
    if (error) {
        NSLog(@"Error writing armored key: %@", error);
        return nil;
    }
    
    return [pgp initNetPGPForMode:PGPModeSign] ? pgp : nil;
}


+ (instancetype)verifier {
    PGP *pgp = [self pgp];
    
    return [pgp initNetPGPForMode:PGPModeVerify] ? pgp : nil;
}


#pragma mark Init/dealloc


- (instancetype)init {
    self = [super init];
    
    if (self != nil) {
        _uuid = [NSUUID UUID];
    }
    
    return self;
}


- (void)dealloc {
    if (self.netpgp != NULL) {
        netpgp_end(self.netpgp);
        free(self.netpgp);
        
        _netpgp = NULL;
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.homedir]) {
        [[NSFileManager defaultManager] removeItemAtPath:self.homedir error:nil];
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.outPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:self.outPath error:nil];
    }
}


#pragma mark Methods


- (void)generateKeysWithOptions:(NSDictionary *)options
                completionBlock:(void(^)(NSString *publicKey, NSString *privateKey))completionBlock
                     errorBlock:(void(^)(NSError *error))errorBlock {
    
    // Get the options out:
    NSNumber *keyType = options[PGPOptionKeyType] ? options[PGPOptionKeyType] : @(DEFAULT_KEY_TYPE);
    NSNumber *numBits = options[PGPOptionNumBits] ? options[PGPOptionNumBits] : @(DEFAULT_BIT_COUNT);
    NSString *userId = options[PGPOptionUserId] ?: PGPDefaultUsername;
    
    if (keyType.intValue != 1) {
        NSString *cause = [NSString stringWithFormat:@"Key type '%li' passed in, only key type '1' (RSA) supported.", (long) keyType.integerValue];
        
        errorBlock([PGP errorWithCause:cause]);
    }
    
    if (!netpgp_generate_key(self.netpgp, (char *)userId.UTF8String, numBits.intValue)) {
        errorBlock([PGP errorWithCause:@"Generate key failed."]);
    }
    
    NSError *error;
    NSString *publicKeyArmored = [self readPubringWithError:&error];
    if (error) {
        errorBlock(error);
        return;
    }
    
    NSString *privateKeyArmored = [self readSecringWithError:&error];
    if (error) {
        errorBlock(error);
        return;
    }
    
    if (publicKeyArmored && privateKeyArmored) {
        completionBlock(publicKeyArmored, privateKeyArmored);
    }
}


- (void)decryptData:(NSData *)data
    completionBlock:(void(^)(NSData *decryptedData))completionBlock
         errorBlock:(void(^)(NSError *error))errorBlock {
    
    if (data == nil) {
        errorBlock([PGP errorWithCause:@"PGP decryptData: Data can not be nil."]);
        return;
    }
    
    NSInteger maxsize = [@DEFAULT_MEMORY_SIZE integerValue];
    void *outbuf = calloc(maxsize, sizeof(Byte));
    
    if (outbuf == NULL) {
        errorBlock([PGP errorWithCause:@"PGP decryptData: Failed to calloc outbuf."]);
        return;
    }
    
    int outsize = netpgp_decrypt_memory(self.netpgp, (void *) data.bytes, data.length, outbuf, maxsize, SHOULD_ARMOR);
    
    if (outsize > 0) {
        completionBlock([NSData dataWithBytesNoCopy:outbuf length:outsize freeWhenDone:YES]);
    } else {
        errorBlock([PGP errorWithCause:@"PGP decryptData: Failed to decrypt."]);
        free(outbuf);
        outbuf = NULL;
    }
}


- (void)encryptData:(NSData *)data
          publicKey:(NSString *)publicKey
    completionBlock:(void(^)(NSData *encryptedData))completionBlock
         errorBlock:(void(^)(NSError *error))errorBlock {
    
    if (data == nil || publicKey == nil) {
        errorBlock([PGP errorWithCause:@"PGP encryptData: Neither data nor publicKey can be nil."]);
        return;
    }
    
    if (![self importPublicKey:publicKey]) {
        errorBlock([PGP errorWithCause:@"Failed to import"]);
    }
    
    NSInteger maxsize = [@DEFAULT_MEMORY_SIZE integerValue];
    
    void *outbuf = calloc(maxsize, sizeof(Byte));
    if (outbuf == NULL) {
        errorBlock([PGP errorWithCause:@"PGP decryptData: Failed to calloc outbuf."]);
        return;
    }
    
    int outsize = netpgp_encrypt_memory_single(self.netpgp, (void *) data.bytes, data.length, outbuf, maxsize, SHOULD_ARMOR);
    
    if (outsize > 0) {
        completionBlock([NSData dataWithBytesNoCopy:outbuf length:outsize freeWhenDone:YES]);
    } else {
        errorBlock([PGP errorWithCause:@"PGP encryptData: Failed to encrypt."]);
        free(outbuf);
        outbuf = NULL;
    }
}


- (void)encryptData:(NSData *)data
         publicKeys:(NSArray *)publicKeys
    completionBlock:(void(^)(NSData *encryptedData))completionBlock
         errorBlock:(void(^)(NSError *error))errorBlock {
    
    if (data == nil || publicKeys == nil) {
        errorBlock([PGP errorWithCause:@"PGP encryptData: Neither data nor publicKeys can be nil."]);
        return;
    }
    
    for (NSString *publicKey in publicKeys) {
        if (![self importPublicKey:publicKey]) {
            errorBlock([PGP errorWithCause:@"PGP encryptData (multiple): Failed to import"]);
        }
    }
    
    NSInteger maxsize = [@DEFAULT_MEMORY_SIZE integerValue];
    
    void *outbuf = calloc(maxsize, sizeof(Byte));
    
    if (outbuf == NULL) {
        errorBlock([PGP errorWithCause:@"PGP decryptData: Failed to calloc outbuf."]);
        return;
    }
    
    int outsize = netpgp_encrypt_memory_multiple(self.netpgp, (void *) data.bytes, data.length, outbuf, maxsize, SHOULD_ARMOR);
    
    if (outsize > 0) {
        completionBlock([NSData dataWithBytesNoCopy:outbuf length:outsize freeWhenDone:YES]);
    } else {
        errorBlock([PGP errorWithCause:@"PGP encryptData (multiple): Failed to encrypt."]);
        free(outbuf);
        outbuf = NULL;
    }
}


- (void)signData:(NSData *)data
 completionBlock:(void (^)(NSData *))completionBlock
      errorBlock:(void (^)(NSError *))errorBlock {
    
    if (data == nil) {
        errorBlock([PGP errorWithCause:@"PGP signData: data can not be nil."]);
        return;
    }
    
    NSInteger maxsize = [@DEFAULT_MEMORY_SIZE integerValue];
    
    void *outbuf = calloc(maxsize, sizeof(Byte));
    
    if (outbuf == NULL) {
        return;
    }
    
    int outsize = netpgp_sign_memory(self.netpgp, (void *) data.bytes, data.length, outbuf, maxsize, SHOULD_ARMOR, CLEARTEXT);
    
    if (outsize > 0) {
        completionBlock([NSData dataWithBytesNoCopy:outbuf length:outsize freeWhenDone:YES]);
    } else {
        errorBlock([PGP errorWithCause:@"Failed to encrypt."]);
        free(outbuf);
        outbuf = NULL;
    }
}


- (void)verifyData:(NSData *)data
        publicKeys:(NSArray *)publicKeys
   completionBlock:(void (^)(NSString *, NSArray *))completionBlock
        errorBlock:(void (^)(NSError *))errorBlock {
    
    if (data == nil || publicKeys == nil) {
        errorBlock([PGP errorWithCause:@"PGP verifyData: Neither data nor publicKeys can be nil."]);
        return;
    }
    
    if (publicKeys.count < 1) {
        errorBlock([PGP errorWithCause:@"PGP verifyData: Public keys is empty."]);
        return;
    }
    
    for (NSString *publicKey in publicKeys) {
        if (![self importPublicKey:publicKey]) {
            errorBlock([PGP errorWithCause:@"PGP verifyData: Failed to import"]);
        }
    }
    
    [self verifyData:data keyCount:publicKeys.count completionBlock:completionBlock errorBlock:errorBlock];
}

- (void)verifyData:(NSData *)data
          keyCount:(NSUInteger)keyCount
   completionBlock:(void (^)(NSString *, NSArray *))completionBlock errorBlock:(void (^)(NSError *))errorBlock {
    
    // Silences analyzer warning:
    NSUInteger count = keyCount;
    char **resultKeyIds = calloc(count, sizeof(char *));
    
    if (resultKeyIds == NULL) {
        errorBlock([PGP errorWithCause:@"PGP verifyData: Failed to alloc key array."]);
        return;
    }
    
    NSInteger maxsize = [@DEFAULT_MEMORY_SIZE integerValue];
    void *outbuf = calloc(maxsize, sizeof(Byte));
    
    if (outbuf == NULL) {
        errorBlock([PGP errorWithCause:@"PGP decryptData: Failed to calloc outbuf."]);
        return;
    }
    
    size_t validSignatureCount = 0;
    int outsize = netpgp_verify_memory(self.netpgp,
                                       data.bytes, data.length,
                                       outbuf, maxsize,
                                       resultKeyIds, &validSignatureCount,
                                       0);
    
    NSMutableArray *verifiedKeyIds = [NSMutableArray array];
    
    for (int i = 0; i < validSignatureCount; i++) {
        char *verifiedKeyId = resultKeyIds[i];
        
        if (verifiedKeyId) {
            NSString *userId = [self userIdForKeyId:verifiedKeyId];
            [verifiedKeyIds addObject:userId];
            
            free(verifiedKeyId);
            resultKeyIds[i] = NULL;
        }
    }
    
    if (resultKeyIds) {
        free(resultKeyIds);
        resultKeyIds = NULL;
    }
    
    if (outsize > 0) {
        NSData *outputData = [NSData dataWithBytesNoCopy:outbuf length:outsize freeWhenDone:YES];
        NSString *outputMessage = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        
        completionBlock(outputMessage, [NSArray arrayWithArray:verifiedKeyIds]);
    } else {
        errorBlock([PGP errorWithCause:@"Failed to verify."]);
        
        free(outbuf);
        outbuf = NULL;
    }
}

#define KEY_ID_LENGTH 16

- (void)decryptAndVerifyData:(NSData *)data
                  publicKeys:(NSArray *)publicKeys
             completionBlock:(void (^)(NSString *, NSArray *))completionBlock
                  errorBlock:(void (^)(NSError *))errorBlock {
    
    
    if (data == nil || publicKeys == nil) {
        errorBlock([PGP errorWithCause:@"PGP verifyData: Neither data nor publicKeys can be nil."]);
        return;
    }
    
    if (publicKeys.count < 1) {
        errorBlock([PGP errorWithCause:@"PGP verifyData: Public keys is empty."]);
        return;
    }
    
    for (NSString *publicKey in publicKeys) {
        if (![self importPublicKey:publicKey]) {
            errorBlock([PGP errorWithCause:@"PGP verifyData: Failed to import"]);
        }
    }
    
    // Silences analyzer warning:
    NSUInteger count = publicKeys.count;
    char **resultKeyIds = calloc(count, sizeof(char *));
    
    if (resultKeyIds == NULL) {
        errorBlock([PGP errorWithCause:@"PGP verifyData: Failed to alloc key array."]);
        return;
    }
    
    NSInteger maxsize = [@DEFAULT_MEMORY_SIZE integerValue];
    
    void *outbuf = calloc(maxsize, sizeof(Byte));
    
    if (outbuf == NULL) {
        errorBlock([PGP errorWithCause:@"PGP decryptData: Failed to calloc outbuf."]);
        return;
    }
    
    int outsize = netpgp_decrypt_memory(self.netpgp, (void *) data.bytes, data.length, outbuf, maxsize, SHOULD_ARMOR);
    
    if (outsize > 0) {
        NSData *outputData = [NSData dataWithBytesNoCopy:outbuf length:outsize freeWhenDone:NO];
        NSString *outputString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
        
        if ([self isArmored:outputString]) {
            
            [self verifyData:outputData keyCount:publicKeys.count completionBlock:completionBlock errorBlock:errorBlock];
            
        } else {
            size_t message_size = outsize - KEY_ID_LENGTH;
            
            char key_id[KEY_ID_LENGTH + 1];
            memcpy(key_id, outbuf + message_size, KEY_ID_LENGTH);
            key_id[KEY_ID_LENGTH] = '\0';
            
            NSData *messageData = [NSData dataWithBytes:outbuf length:message_size];
            NSString *userId = [self userIdForKeyId:key_id];
            
            completionBlock([[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding], @[userId]);
        }
        
    } else {
        errorBlock([PGP errorWithCause:@"PGP decryptData: Failed to decrypt."]);
    }
    
    free(outbuf);
    outbuf = NULL;
}

- (NSString *)userIdForKeyId:(char *)key_id {
    
    char user_id[256];
    memset(user_id, 0, 256);
    
    netpgp_userid_for_keyid(self.netpgp, key_id, user_id);
    return [NSString stringWithCString:user_id encoding:NSUTF8StringEncoding];
}

- (BOOL)isArmored:(NSString *)text {
    return [text containsString:@"-----BEGIN PGP MESSAGE-----"];
}


#pragma mark Properties


- (NSString *)homedir {
    if (_homedir == nil) {
        NSString *keyDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"keys"];
        _homedir = [keyDirectory stringByAppendingPathComponent:self.uuid.UUIDString];
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:_homedir]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:_homedir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        }
    }
    
    return _homedir;
}


- (NSString *)pubringPath {
    if (_pubringPath == nil) {
        _pubringPath = [self.homedir stringByAppendingPathComponent:PGPPubringFilename];
        if (![[NSFileManager defaultManager] fileExistsAtPath:_pubringPath]) {
            [[NSFileManager defaultManager] createFileAtPath:_pubringPath
                                                    contents:nil
                                                  attributes:@{NSFilePosixPermissions: [NSNumber numberWithShort:0600]}];
        }
    }
    
    return _pubringPath;
}


- (NSString *)secringPath {
    if (_secringPath == nil) {
        _secringPath = [self.homedir stringByAppendingPathComponent:PGPSecringFilename];
        if (![[NSFileManager defaultManager] fileExistsAtPath:_secringPath]) {
            [[NSFileManager defaultManager] createFileAtPath:_secringPath
                                                    contents:nil
                                                  attributes:@{NSFilePosixPermissions: [NSNumber numberWithShort:0600]}];
        }
    }
    
    return _secringPath;
}


- (NSString *)outPath {
    if (_outPath == nil) {
        
        NSString *logDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"logs"];
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:logDirectory]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:logDirectory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        }
        
        _outPath = [[logDirectory stringByAppendingPathComponent:_uuid.UUIDString] stringByAppendingPathExtension:@"log"];
        
        [[NSFileManager defaultManager] createFileAtPath:_outPath
                                                contents:nil
                                              attributes:@{NSFilePosixPermissions: [NSNumber numberWithShort:0600]}];
    }
    
    return _outPath;
}


#pragma mark Class private


+ (instancetype)pgp {
    return [[self alloc] init];
}


+ (NSError *)errorWithCause:(NSString *)cause {
    return [NSError errorWithDomain:@"PGP"
                               code:-1
                           userInfo:@{@"cause": cause}];
}


+ (NSString *)generateTemporaryPath {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
}


#pragma mark Private methods


- (BOOL)initNetPGPForMode:(PGPMode)mode {
    _netpgp = calloc(0x1, sizeof(netpgp_t));
    
    netpgp_setvar(_netpgp, "hash", DEFAULT_HASH_ALG);
    netpgp_setvar(_netpgp, "max mem alloc", "4194304");
    netpgp_setvar(_netpgp, "res", self.outPath.UTF8String);
    
    switch (mode) {
        case PGPModeGenerate:
            // Generate skips userid checking:
            netpgp_setvar(_netpgp, "userid checks", "skip");
            break;
            
        case PGPModeDecrypt:
            // Decrypt requires seckey:
            netpgp_setvar(_netpgp, "need seckey", "1");
            netpgp_setvar(_netpgp, "cipher", "aes256");
            break;
            
        case PGPModeEncrypt:
            // Encrypt requires userid:
            netpgp_setvar(_netpgp, "cipher", "aes256");
            break;
            
        case PGPModeSign:
            // Sign requires userid and seckey:
            netpgp_setvar(_netpgp, "need seckey", "1");
            netpgp_setvar(_netpgp, "cipher", "aes256");
            break;
            
        case PGPModeVerify:
            netpgp_setvar(_netpgp, "cipher", "aes256");
            break;
    }
    
    //    netpgp_incvar(_netpgp, "verbose", 1);
    //    netpgp_set_debug(NULL);
    
    netpgp_set_homedir(_netpgp, (char *) self.homedir.UTF8String, NULL, 0);
    netpgp_setvar(_netpgp, "pubring", (char *) self.pubringPath.UTF8String);
    netpgp_setvar(_netpgp, "secring", (char *) self.secringPath.UTF8String);
    
    return netpgp_init(_netpgp);
}


- (NSString *)readPubringWithError:(NSError **)error {
    return [NSString stringWithContentsOfFile:self.pubringPath
                                     encoding:NSUTF8StringEncoding
                                        error:error];
}


- (NSString *)readSecringWithError:(NSError **)error {
    return [NSString stringWithContentsOfFile:self.secringPath
                                     encoding:NSUTF8StringEncoding
                                        error:error];
}


- (void)writeSecringWithArmoredKey:(NSString *)armoredKey error:(NSError **)error {
    [armoredKey writeToFile:self.secringPath atomically:YES encoding:NSUTF8StringEncoding error:error];
}


- (BOOL)importPublicKey:(NSString *)publicKey {
    NSString *temporaryDirectory = [PGP generateTemporaryPath];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:temporaryDirectory]) {
        @throw [NSException exceptionWithName:@"PGPException"
                                       reason:@"File already exists at temporary path!"
                                     userInfo:@{@"path": temporaryDirectory}];
    }
    
    [[NSFileManager defaultManager] createDirectoryAtPath:temporaryDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSString *temporaryPath = [temporaryDirectory stringByAppendingPathComponent:@"tempring.gpg"];
    
    [[NSFileManager defaultManager] createFileAtPath:temporaryPath
                                            contents:[publicKey dataUsingEncoding:NSUTF8StringEncoding]
                                          attributes:@{NSFilePosixPermissions: [NSNumber numberWithShort:0600]}];
    
    BOOL success = netpgp_import_key(self.netpgp, (char *) temporaryPath.UTF8String);
    
    [[NSFileManager defaultManager] removeItemAtPath:temporaryDirectory error:nil];
    
    return success;
}


@end

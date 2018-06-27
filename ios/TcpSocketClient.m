/**
 * Copyright (c) 2015-present, Peel Technologies, Inc.
 * All rights reserved.
 */

#import <netinet/in.h>
#import <arpa/inet.h>
#import "TcpSocketClient.h"

#import <React/RCTLog.h>

NSString *const RCTTCPErrorDomain = @"RCTTCPErrorDomain";

@interface TcpSocketClient()
{
@private
	GCDAsyncSocket *_tcpSocket;
	NSMutableDictionary<NSNumber *, RCTResponseSenderBlock> *_pendingSends;
	NSLock *_lock;
	long _sendTag;
}

- (id)initWithClientId:(NSNumber *)clientID andConfig:(id<SocketClientDelegate>)aDelegate;
- (id)initWithClientId:(NSNumber *)clientID andConfig:(id<SocketClientDelegate>)aDelegate andSocket:(GCDAsyncSocket*)tcpSocket;

@end

@implementation TcpSocketClient

+ (id)socketClientWithId:(nonnull NSNumber *)clientID andConfig:(id<SocketClientDelegate>)delegate {
	return [[[self class] alloc] initWithClientId:clientID andConfig:delegate andSocket:nil];
}

- (id)initWithClientId:(NSNumber *)clientID andConfig:(id<SocketClientDelegate>)aDelegate {
	return [self initWithClientId:clientID andConfig:aDelegate andSocket:nil];
}

- (id)initWithClientId:(NSNumber *)clientID andConfig:(id<SocketClientDelegate>)aDelegate andSocket:(GCDAsyncSocket*)tcpSocket;
{
	self = [super init];
	if (self) {
		_id = clientID;
		_clientDelegate = aDelegate;
		_pendingSends = [NSMutableDictionary dictionary];
		_lock = [[NSLock alloc] init];
		_tcpSocket = tcpSocket;
		[_tcpSocket setUserData: clientID];
	}
	
	return self;
}

- (BOOL)connect:(NSString *)host port:(int)port withOptions:(NSDictionary *)options error:(NSError **)error {
	
	if (_tcpSocket) {
		if (error) {
			*error = [self badInvocationError:@"this client's socket is already connected"];
		}
		return false;
	}
	
	_isSecure = (port == 9182) ? true : false;
	
	_tcpSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
	[_tcpSocket setUserData: _id];
	
	if (_isSecure == true) {
		return [_tcpSocket connectToHost:host onPort:port withTimeout:([@"60000" intValue] / 1000) error:error];
	} else {
		NSString *localAddress = (options?options[@"localAddress"]:nil);
		NSNumber *localPort = (options?options[@"localPort"]:nil);
		
		if (!localAddress && !localPort) {
			return [_tcpSocket connectToHost:host onPort:port error:error];
		} else {
			NSMutableArray *interface = [NSMutableArray arrayWithCapacity:2];
			[interface addObject: localAddress?localAddress:@""];
			if (localPort) {
				[interface addObject:[localPort stringValue]];
			}
			return [_tcpSocket connectToHost:host onPort:port viaInterface:[interface componentsJoinedByString:@":"] withTimeout:-1 error:error];
		}
	}
}

- (NSDictionary<NSString *, id> *)getAddress {
	
	if (_tcpSocket) {
		if (_tcpSocket.isConnected) {
			return @{ @"port": @(_tcpSocket.connectedPort), @"address": _tcpSocket.connectedHost ?: @"unknown", @"family": _tcpSocket.isIPv6?@"IPv6":@"IPv4" };
		} else {
			return @{ @"port": @(_tcpSocket.localPort), @"address": _tcpSocket.localHost ?: @"unknown", @"family": _tcpSocket.isIPv6?@"IPv6":@"IPv4" };
		}
	}
	return @{ @"port": @(0), @"address": @"unknown", @"family": @"unkown" };
}

- (BOOL)listen:(NSString *)host port:(int)port error:(NSError **)error {
	
	if (_tcpSocket) {
		if (error) {
			*error = [self badInvocationError:@"this client's socket is already connected"];
		}
		return false;
	}
	
	if (_isSecure) {
		return true;
	} else {
		_tcpSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
		[_tcpSocket setUserData: _id];
		
		// GCDAsyncSocket doesn't recognize 0.0.0.0
		if ([@"0.0.0.0" isEqualToString: host]) {
			host = @"localhost";
		}
		BOOL isListening = [_tcpSocket acceptOnInterface:host port:port error:error];
		if (isListening == YES) {
			
			[_clientDelegate onConnect: self];
			[_tcpSocket readDataWithTimeout:-1 tag:_id.longValue];
		}
		return isListening;
	}
}

- (void)setPendingSend:(RCTResponseSenderBlock)callback forKey:(NSNumber *)key {
	
	if (!_isSecure) {
		[_lock lock];
		@try {
			[_pendingSends setObject:callback forKey:key];
		}
		@finally {
			[_lock unlock];
		}
	}
}

- (RCTResponseSenderBlock)getPendingSend:(NSNumber *)key {
	
	[_lock lock];
	@try {
		return [_pendingSends objectForKey:key];
	}
	@finally {
		[_lock unlock];
	}
}

- (void)dropPendingSend:(NSNumber *)key {
	
	if (_isSecure) {
		NSLog(@"do nothing");
	} else {
		[_lock lock];
		@try {
			[_pendingSends removeObjectForKey:key];
		}
		@finally {
			[_lock unlock];
		}
	}
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)msgTag {
	
	if (!_isSecure) {
		NSNumber* tagNum = [NSNumber numberWithLong:msgTag];
		RCTResponseSenderBlock callback = [self getPendingSend:tagNum];
		if (callback) {
			callback(@[]);
			[self dropPendingSend:tagNum];
		}
	}
}

- (void) writeData:(NSData *)data callback:(RCTResponseSenderBlock)callback {
	
	if (callback) {
		[self setPendingSend:callback forKey:@(_sendTag)];
	}
	
	if (_isSecure) {
		[_tcpSocket writeData:data withTimeout:60 tag:0];
		[_tcpSocket readDataToData:[GCDAsyncSocket LFData] withTimeout:60 tag:0];
		_sendTag++;
	} else {
		[_tcpSocket writeData:data withTimeout:-1 tag:_sendTag];
		[_tcpSocket readDataWithTimeout:-1 tag:_id.longValue];
		_sendTag++;
	}
}

- (void)end {
	[_tcpSocket disconnectAfterWriting];
}

- (void)destroy {
	[_tcpSocket disconnect];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
	
	if (!_clientDelegate) {
		RCTLogWarn(@"didReadData with nil clientDelegate for %@", [sock userData]);
		return;
	}
	
	if (_isSecure) {
		[_clientDelegate onData:@(tag) data:data];
		[_tcpSocket setDelegate:nil delegateQueue:NULL];
		[_tcpSocket disconnect];
	} else {
		[_clientDelegate onData:@(tag) data:data];
		[sock readDataWithTimeout:-1 tag:tag];
	}
}

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
	
	if (!_isSecure) {
		TcpSocketClient *inComing = [[TcpSocketClient alloc] initWithClientId:[_clientDelegate getNextId]
																	andConfig:_clientDelegate
																	andSocket:newSocket];
		
		[_clientDelegate onConnection: inComing
							 toClient: _id];
		[newSocket readDataWithTimeout:-1 tag:inComing.id.longValue];
	}
}

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port
{
	if (!_clientDelegate) {
		RCTLogWarn(@"didConnectToHost with nil clientDelegate for %@", [sock userData]);
		return;
	}
	
	if (_isSecure) {
		[sock performBlock:^{
			if ([sock enableBackgroundingOnSocket]) {
				NSLog(@"Enabled backgrounding on socket");
			} else {
				NSLog(@"Enabling backgrounding failed!");
			}
		}];
		
		NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithCapacity:3];
		[sock startTLS:settings];
		
	} else {
		[_clientDelegate onConnect:self];
		[sock readDataWithTimeout:-1 tag:_id.longValue];
	}
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock {
	[_clientDelegate onConnect:self];
}

- (void)socketDidCloseReadStream:(GCDAsyncSocket *)sock {
	[sock disconnect];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
	if (!_clientDelegate) {
		RCTLogWarn(@"socketDidDisconnect with nil clientDelegate for %@", [sock userData]);
		return;
	}
	
	[_clientDelegate onClose:[sock userData] withError:(!err || err.code == GCDAsyncSocketClosedError ? nil : err)];
}

- (NSError *)badInvocationError:(NSString *)errMsg {
	NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];
	return [NSError errorWithDomain:RCTTCPErrorDomain code:RCTTCPInvalidInvocationError userInfo:userInfo];
}

@end

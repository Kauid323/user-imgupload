#import <Foundation/Foundation.h>

#if __has_include(<CommonCrypto/CommonDigest.h>)
#import <CommonCrypto/CommonDigest.h>
#define IMGUTIL_HAVE_COMMONCRYPTO 1
#else
#define IMGUTIL_HAVE_COMMONCRYPTO 0
#endif

static NSString * const kDefaultUploadHost = @"upload-z2.qiniup.com";

static BOOL ImgUtilDebugEnabled(void) {
  NSString *v = [NSProcessInfo processInfo].environment[@"IMGUTIL_DEBUG"];
  return v.length > 0 && ![v isEqualToString:@"0"];
}

static void ImgUtilDebugLog(NSString *msg) {
  if (ImgUtilDebugEnabled()) {
    fprintf(stderr, "[debug] %s\n", msg.UTF8String);
  }
}

static void Die(NSString *msg) {
  fprintf(stderr, "%s\n", msg.UTF8String);
  exit(1);
}

static NSString *NormalizeInput(NSString *s) {
  NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  while ([t hasSuffix:@"+"]) {
    t = [[t substringToIndex:t.length - 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  }
  if (t.length >= 2) {
    unichar a = [t characterAtIndex:0];
    unichar b = [t characterAtIndex:t.length - 1];
    if ((a == '"' && b == '"') || (a == '\'' && b == '\'')) {
      t = [t substringWithRange:NSMakeRange(1, t.length - 2)];
    }
  }
  return t;
}

static BOOL IsUrl(NSString *s) {
  return [s hasPrefix:@"http://"] || [s hasPrefix:@"https://"];
}

static NSData *ReadFileBytes(NSString *path) {
  NSData *d = [NSData dataWithContentsOfFile:path options:0 error:nil];
  return d;
}

static NSData *HttpGetBytes(NSString *urlString, NSDictionary<NSString*, NSString*> *headers, NSInteger timeoutSec, NSInteger *outStatus, NSString **outBodyTextOnError) {
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url) return nil;

  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  req.timeoutInterval = timeoutSec;
  for (NSString *k in headers) {
    [req setValue:headers[k] forHTTPHeaderField:k];
  }

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSData *respData = nil;
  __block NSHTTPURLResponse *httpResp = nil;
  __block NSError *err = nil;

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
    respData = data;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
      httpResp = (NSHTTPURLResponse *)response;
    }
    err = error;
    dispatch_semaphore_signal(sem);
  }];

  [task resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutSec * NSEC_PER_SEC));

  if (outStatus) {
    *outStatus = httpResp ? httpResp.statusCode : 0;
  }

  if (err) {
    if (outBodyTextOnError) {
      *outBodyTextOnError = [NSString stringWithFormat:@"request error: %@", err.localizedDescription];
    }
    return nil;
  }

  return respData;
}

static NSString *Md5Hex(NSData *data) {
  if (!data) return @"";

#if IMGUTIL_HAVE_COMMONCRYPTO
  unsigned char digest[CC_MD5_DIGEST_LENGTH];
  CC_MD5(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *s = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
    [s appendFormat:@"%02x", digest[i]];
  }
  return s;
#else
  return @"";
#endif
}

static NSString *TempPath(NSString *ext) {
  NSString *dir = NSTemporaryDirectory();
  NSString *name = [NSString stringWithFormat:@"imgutil_%@.%@", [[NSUUID UUID] UUIDString], ext];
  return [dir stringByAppendingPathComponent:name];
}

static NSData *RunCwebp(NSData *inputBytes, NSInteger quality) {
  NSInteger q = quality;
  if (q <= 0 || q > 100) q = 95;

  NSString *inPath = TempPath(@"input");
  NSString *outPath = TempPath(@"webp");

  if (![inputBytes writeToFile:inPath atomically:YES]) {
    return nil;
  }

  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"cwebp";
  task.arguments = @[ @"-q", [NSString stringWithFormat:@"%ld", (long)q], inPath, @"-o", outPath ];

  NSPipe *pipe = [NSPipe pipe];
  task.standardError = pipe;
  task.standardOutput = pipe;

  @try {
    [task launch];
    [task waitUntilExit];
  } @catch (NSException *ex) {
    [[NSFileManager defaultManager] removeItemAtPath:inPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    return nil;
  }

  [[NSFileManager defaultManager] removeItemAtPath:inPath error:nil];

  if (task.terminationStatus != 0) {
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    return nil;
  }

  NSData *out = [NSData dataWithContentsOfFile:outPath options:0 error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
  return out;
}

static NSDictionary *LoadConfig(NSString *path) {
  NSData *d = [NSData dataWithContentsOfFile:path options:0 error:nil];
  if (!d) return nil;
  id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  if (![obj isKindOfClass:[NSDictionary class]]) return nil;
  return (NSDictionary *)obj;
}

static NSString *GetString(NSDictionary *d, NSString *k, NSString *defv) {
  id v = d[k];
  if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
  return defv;
}

static BOOL GetBool(NSDictionary *d, NSString *k, BOOL defv) {
  id v = d[k];
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
  return defv;
}

static NSInteger GetInt(NSDictionary *d, NSString *k, NSInteger defv) {
  id v = d[k];
  if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v integerValue];
  return defv;
}

static NSString *GetQiniuUploadToken(NSString *userToken, NSString *tokenUrl) {
  NSInteger status = 0;
  NSString *errText = nil;
  NSData *d = HttpGetBytes(tokenUrl, @{ @"token": userToken, @"Content-Type": @"application/json" }, 60, &status, &errText);

  if (ImgUtilDebugEnabled()) {
    ImgUtilDebugLog([NSString stringWithFormat:@"qiniu-token status=%ld", (long)status]);
    if (d) {
      NSString *body = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
      ImgUtilDebugLog([NSString stringWithFormat:@"qiniu-token body=%@", body]);
    } else if (errText) {
      ImgUtilDebugLog([NSString stringWithFormat:@"qiniu-token err=%@", errText]);
    }
  }

  if (!d || status < 200 || status >= 300) return @"";

  id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  if (![obj isKindOfClass:[NSDictionary class]]) return @"";
  NSDictionary *dict = (NSDictionary *)obj;
  NSNumber *code = dict[@"code"];
  if (![code isKindOfClass:[NSNumber class]] || code.integerValue != 1) return @"";

  NSString *tok = nil;
  id data = dict[@"data"];
  if ([data isKindOfClass:[NSDictionary class]]) {
    id t = ((NSDictionary *)data)[@"token"];
    if ([t isKindOfClass:[NSString class]]) tok = (NSString *)t;
  }
  if (!tok) {
    id t2 = dict[@"token"];
    if ([t2 isKindOfClass:[NSString class]]) tok = (NSString *)t2;
  }
  return tok ?: @"";
}

static NSString *QueryUploadHost(NSString *uploadToken, NSString *bucket) {
  NSString *ak = uploadToken;
  NSRange r = [uploadToken rangeOfString:@":"];
  if (r.location != NSNotFound) {
    ak = [uploadToken substringToIndex:r.location];
  }
  NSString *url = [NSString stringWithFormat:@"https://api.qiniu.com/v4/query?ak=%@&bucket=%@",
                   [ak stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                   [bucket stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

  NSInteger status = 0;
  NSString *errText = nil;
  NSData *d = HttpGetBytes(url, @{}, 60, &status, &errText);
  if (!d || status < 200 || status >= 300) return kDefaultUploadHost;

  id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  if (![obj isKindOfClass:[NSDictionary class]]) return kDefaultUploadHost;
  id domains = ((NSDictionary *)obj)[@"domains"];
  if ([domains isKindOfClass:[NSArray class]] && [(NSArray *)domains count] > 0) {
    id first = ((NSArray *)domains)[0];
    if ([first isKindOfClass:[NSString class]]) {
      NSString *h = (NSString *)first;
      h = [h stringByReplacingOccurrencesOfString:@"http://" withString:@""];
      h = [h stringByReplacingOccurrencesOfString:@"https://" withString:@""];
      NSRange slash = [h rangeOfString:@"/"];
      if (slash.location != NSNotFound) {
        h = [h substringToIndex:slash.location];
      }
      if (h.length > 0) return h;
    }
  }
  return kDefaultUploadHost;
}

static NSDictionary *UploadOnce(NSString *uploadUrl, NSString *uploadToken, NSString *key, NSData *fileBytes, NSString *mimeType, NSInteger *outStatus, NSString **outBody) {
  NSString *boundary = [NSString stringWithFormat:@"----imgutil%@", [[NSUUID UUID] UUIDString]];
  NSMutableData *body = [NSMutableData data];
  NSData *(^s2d)(NSString *) = ^NSData *(NSString *s) {
    return [s dataUsingEncoding:NSUTF8StringEncoding];
  };

  [body appendData:s2d([NSString stringWithFormat:@"--%@\r\n", boundary])];
  [body appendData:s2d(@"Content-Disposition: form-data; name=\"token\"\r\n\r\n")];
  [body appendData:s2d(uploadToken)];
  [body appendData:s2d(@"\r\n")];

  [body appendData:s2d([NSString stringWithFormat:@"--%@\r\n", boundary])];
  [body appendData:s2d(@"Content-Disposition: form-data; name=\"key\"\r\n\r\n")];
  [body appendData:s2d(key)];
  [body appendData:s2d(@"\r\n")];

  [body appendData:s2d([NSString stringWithFormat:@"--%@\r\n", boundary])];
  [body appendData:s2d([NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", key])];
  [body appendData:s2d([NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimeType])];
  [body appendData:fileBytes];
  [body appendData:s2d(@"\r\n")];

  [body appendData:s2d([NSString stringWithFormat:@"--%@--\r\n", boundary])];

  NSURL *url = [NSURL URLWithString:uploadUrl];
  if (!url) return nil;

  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"POST";
  [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"]; 
  [req setValue:@"QiniuDart" forHTTPHeaderField:@"User-Agent"]; 
  req.HTTPBody = body;
  req.timeoutInterval = 120;

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSData *respData = nil;
  __block NSHTTPURLResponse *httpResp = nil;
  __block NSError *err = nil;

  NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
    respData = data;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
      httpResp = (NSHTTPURLResponse *)response;
    }
    err = error;
    dispatch_semaphore_signal(sem);
  }];
  [task resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)120 * NSEC_PER_SEC));

  NSInteger status = httpResp ? httpResp.statusCode : 0;
  if (outStatus) *outStatus = status;

  NSString *respText = @"";
  if (respData) {
    respText = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] ?: @"";
  }
  if (outBody) *outBody = respText;

  if (err) {
    return @{ @"ok": @NO, @"status": @(status), @"body": respText.length ? respText : err.localizedDescription };
  }
  return @{ @"ok": @YES, @"status": @(status), @"body": respText };
}

static void PrettyPrintJsonString(NSString *raw) {
  NSData *d = [raw dataUsingEncoding:NSUTF8StringEncoding];
  if (!d) {
    printf("%s\n", raw.UTF8String);
    return;
  }
  id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  if (!obj) {
    printf("%s\n", raw.UTF8String);
    return;
  }
  NSData *pretty = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:nil];
  if (!pretty) {
    printf("%s\n", raw.UTF8String);
    return;
  }
  NSString *s = [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding] ?: raw;
  printf("%s\n", s.UTF8String);
}

int main(int argc, const char * argv[]) {
  @autoreleasepool {
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSString *cfgPath = [cwd stringByAppendingPathComponent:@"config.json"]; 
    NSDictionary *cfgRaw = LoadConfig(cfgPath);
    if (!cfgRaw) {
      Die(@"找不到config.json，请在当前目录放置 config.json");
    }

    NSString *userToken = GetString(cfgRaw, @"user_token", @"");
    BOOL enableWebp = GetBool(cfgRaw, @"enable_webp", NO);
    NSInteger webpQuality = GetInt(cfgRaw, @"webp_quality", 95);
    NSString *bucket = GetString(cfgRaw, @"bucket", @"chat68");
    NSString *tokenUrl = GetString(cfgRaw, @"qiniu_token_url", @"https://chat-go.jwzhd.com/v1/misc/qiniu-token");

    if (userToken.length == 0) {
      Die(@"config.json里的 user_token 为空");
    }

    NSString *input = nil;
    if (argc >= 2) {
      input = [NSString stringWithUTF8String:argv[1]];
    } else {
      printf("请输入图片地址(本地路径或URL): ");
      char buf[4096];
      if (!fgets(buf, sizeof(buf), stdin)) {
        Die(@"未输入图片地址");
      }
      input = [NSString stringWithUTF8String:buf];
    }

    input = NormalizeInput(input ?: @"");
    if (input.length == 0) {
      Die(@"未输入图片地址");
    }

    NSData *origBytes = nil;
    NSString *name = @"image";

    if (IsUrl(input)) {
      NSInteger st = 0;
      NSString *errText = nil;
      NSData *d = HttpGetBytes(input, @{}, 60, &st, &errText);
      if (!d || st < 200 || st >= 300) {
        Die(@"上传失败: download failed");
      }
      origBytes = d;
      NSURL *u = [NSURL URLWithString:input];
      NSString *last = u.path.lastPathComponent;
      if (last.length > 0) name = last;
    } else {
      origBytes = ReadFileBytes(input);
      if (!origBytes) {
        Die(@"上传失败: could not read file");
      }
      name = input.lastPathComponent.length ? input.lastPathComponent : name;
    }

    NSData *uploadBytes = origBytes;
    NSString *mimeType = @"application/octet-stream";
    NSString *ext = @"bin";

    if (enableWebp) {
      NSData *wb = RunCwebp(origBytes, webpQuality);
      if (!wb) {
        Die(@"上传失败: cwebp failed (install cwebp or set enable_webp=false)");
      }
      uploadBytes = wb;
      mimeType = @"image/webp";
      ext = @"webp";
    } else {
      NSString *dotExt = name.pathExtension;
      if (dotExt.length > 0) ext = dotExt;
    }

    NSString *md5 = Md5Hex(uploadBytes);
    if (md5.length == 0) {
      Die(@"上传失败: md5 not available (CommonCrypto not found)");
    }
    NSString *key = [NSString stringWithFormat:@"%@.%@", md5, ext];

    NSString *uploadToken = GetQiniuUploadToken(userToken, tokenUrl);
    if (uploadToken.length == 0) {
      Die(@"上传失败: qiniu-token failed");
    }

    NSString *host = QueryUploadHost(uploadToken, bucket);
    NSString *uploadUrl = [NSString stringWithFormat:@"https://%@", host];

    NSInteger status = 0;
    NSString *body = nil;
    NSDictionary *r = UploadOnce(uploadUrl, uploadToken, key, uploadBytes, mimeType, &status, &body);

    if (ImgUtilDebugEnabled()) {
      ImgUtilDebugLog([NSString stringWithFormat:@"upload status=%ld", (long)status]);
      if (body) ImgUtilDebugLog([NSString stringWithFormat:@"upload body=%@", body]);
    }

    if (status < 200 || status >= 300) {
      if (body && [body rangeOfString:@"no such domain"].location != NSNotFound) {
        uploadUrl = [NSString stringWithFormat:@"https://%@", kDefaultUploadHost];
        r = UploadOnce(uploadUrl, uploadToken, key, uploadBytes, mimeType, &status, &body);
      }
    }

    if (status < 200 || status >= 300) {
      NSString *msg = [NSString stringWithFormat:@"上传失败: qiniu upload failed: %ld %@", (long)status, body ?: @""];
      Die(msg);
    }

    printf("上传成功\n");
    printf("response_json:\n");
    PrettyPrintJsonString(body ?: @"{}");
  }
  return 0;
}

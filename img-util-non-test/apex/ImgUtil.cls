public class ImgUtil {
  public class Config {
    public String userToken;
    public Boolean enableWebp;
    public Integer webpQuality;
    public String bucket;
    public String qiniuTokenUrl;
  }

  public class UploadResult {
    public Integer status;
    public String body;
  }

  public static String getQiniuToken(Config cfg) {
    HttpRequest req = new HttpRequest();
    req.setEndpoint(cfg.qiniuTokenUrl);
    req.setMethod('GET');
    req.setHeader('token', cfg.userToken);
    req.setHeader('Content-Type', 'application/json');

    Http http = new Http();
    HttpResponse resp = http.send(req);
    if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) {
      throw new AuraHandledException('qiniu-token failed');
    }

    Map<String, Object> obj = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
    if (((Integer) obj.get('code')) != 1) throw new AuraHandledException('bad code');
    Map<String, Object> data = (Map<String, Object>) obj.get('data');
    if (data != null && data.containsKey('token')) {
      return (String) data.get('token');
    }
    if (obj.containsKey('token')) {
      return (String) obj.get('token');
    }
    throw new AuraHandledException('missing token');
  }

  public static String queryUploadHost(String uploadToken, String bucket) {
    String ak = uploadToken;
    if (uploadToken != null && uploadToken.contains(':')) {
      ak = uploadToken.substringBefore(':');
    }
    String url = 'https://api.qiniu.com/v4/query?ak=' + EncodingUtil.urlEncode(ak, 'UTF-8')
      + '&bucket=' + EncodingUtil.urlEncode(bucket, 'UTF-8');

    try {
      HttpRequest req = new HttpRequest();
      req.setEndpoint(url);
      req.setMethod('GET');
      HttpResponse resp = new Http().send(req);
      if (resp.getStatusCode() < 200 || resp.getStatusCode() >= 300) return 'upload-z2.qiniup.com';
      Map<String, Object> obj = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
      Object domainsObj = obj.get('domains');
      if (domainsObj instanceof List<Object>) {
        List<Object> domains = (List<Object>) domainsObj;
        if (!domains.isEmpty() && domains[0] instanceof String) {
          String host = (String) domains[0];
          host = host.replace('https://', '').replace('http://', '');
          if (host.contains('/')) host = host.substringBefore('/');
          if (!String.isBlank(host)) return host;
        }
      }
      return 'upload-z2.qiniup.com';
    } catch (Exception e) {
      return 'upload-z2.qiniup.com';
    }
  }

  public static UploadResult uploadOnce(String uploadUrl, String uploadToken, String key, Blob fileBytes, String mimeType) {
    String boundary = '----imgutil' + String.valueOf(Crypto.getRandomInteger());

    String part1 = '--' + boundary + '\r\n'
      + 'Content-Disposition: form-data; name="token"\r\n\r\n'
      + uploadToken + '\r\n'
      + '--' + boundary + '\r\n'
      + 'Content-Disposition: form-data; name="key"\r\n\r\n'
      + key + '\r\n'
      + '--' + boundary + '\r\n'
      + 'Content-Disposition: form-data; name="file"; filename="' + key + '"\r\n'
      + 'Content-Type: ' + (String.isBlank(mimeType) ? 'application/octet-stream' : mimeType) + '\r\n\r\n';

    String part2 = '\r\n--' + boundary + '--\r\n';

    Blob body = Blob.valueOf(part1);
    body = BlobUtil.concat(body, fileBytes);
    body = BlobUtil.concat(body, Blob.valueOf(part2));

    HttpRequest req = new HttpRequest();
    req.setEndpoint(uploadUrl);
    req.setMethod('POST');
    req.setHeader('Content-Type', 'multipart/form-data; boundary=' + boundary);
    req.setHeader('User-Agent', 'QiniuDart');
    req.setBodyAsBlob(body);

    HttpResponse resp = new Http().send(req);
    UploadResult r = new UploadResult();
    r.status = resp.getStatusCode();
    r.body = resp.getBody();
    return r;
  }
}

public class BlobUtil {
  public static Blob concat(Blob a, Blob b) {
    return EncodingUtil.convertFromHex(EncodingUtil.convertToHex(a) + EncodingUtil.convertToHex(b));
  }
}

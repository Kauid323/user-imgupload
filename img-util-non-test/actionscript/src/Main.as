package {
  import flash.display.Sprite;
  import flash.events.Event;
  import flash.events.IOErrorEvent;
  import flash.events.MouseEvent;
  import flash.net.FileReference;
  import flash.net.URLLoader;
  import flash.net.URLLoaderDataFormat;
  import flash.net.URLRequest;
  import flash.net.URLRequestHeader;
  import flash.net.URLRequestMethod;
  import flash.utils.ByteArray;

  public class Main extends Sprite {
    private const DEFAULT_UPLOAD_HOST:String = "upload-z2.qiniup.com";

    private var USER_TOKEN:String = "";
    private var ENABLE_WEBP:Boolean = false;
    private var WEBP_QUALITY:int = 95;
    private var BUCKET:String = "chat68";
    private var TOKEN_URL:String = "https://chat-go.jwzhd.com/v1/misc/qiniu-token";

    private var fileRef:FileReference;

    public function Main() {
      // Minimal: auto open file picker
      fileRef = new FileReference();
      fileRef.addEventListener(Event.SELECT, onFileSelected);
      fileRef.addEventListener(Event.CANCEL, function(e:Event):void { trace("select cancelled"); });

      if (USER_TOKEN.length == 0) {
        trace("user_token empty (edit USER_TOKEN in src/Main.as)");
      }

      fileRef.browse();
    }

    private function onFileSelected(e:Event):void {
      trace("selected: " + fileRef.name);
      fileRef.addEventListener(Event.COMPLETE, onFileLoaded);
      fileRef.addEventListener(IOErrorEvent.IO_ERROR, function(ev:IOErrorEvent):void { trace("file load error: " + ev.text); });
      fileRef.load();
    }

    private function onFileLoaded(e:Event):void {
      if (USER_TOKEN.length == 0) {
        trace("user_token empty");
        return;
      }

      const bytes:ByteArray = fileRef.data;
      const filename:String = fileRef.name;

      getQiniuToken(function(uploadToken:String):void {
        queryUploadHost(uploadToken, function(host:String):void {
          const uploadUrl:String = "https://" + host;
          uploadOnce(uploadUrl, uploadToken, filename, bytes, "application/octet-stream", function(status:int, body:String):void {
            if (status < 200 || status >= 300) {
              if (body.indexOf("no such domain") >= 0) {
                uploadOnce("https://" + DEFAULT_UPLOAD_HOST, uploadToken, filename, bytes, "application/octet-stream", done);
                return;
              }
            }
            done(status, body);
          });

          function done(status:int, body:String):void {
            if (status < 200 || status >= 300) {
              trace("upload failed: " + status + " " + body);
              return;
            }
            trace("upload ok");
            trace(body);
          }
        });
      });
    }

    private function getQiniuToken(cb:Function):void {
      const req:URLRequest = new URLRequest(TOKEN_URL);
      req.method = URLRequestMethod.GET;
      req.requestHeaders = [
        new URLRequestHeader("token", USER_TOKEN),
        new URLRequestHeader("Content-Type", "application/json")
      ];

      const loader:URLLoader = new URLLoader();
      loader.dataFormat = URLLoaderDataFormat.TEXT;
      loader.addEventListener(Event.COMPLETE, function(e:Event):void {
        try {
          const obj:Object = JSON.parse(String(loader.data));
          if (obj.code !== 1) {
            trace("qiniu-token bad code");
            cb("");
            return;
          }
          const tok:String = (obj.data && obj.data.token) ? String(obj.data.token) : (obj.token ? String(obj.token) : "");
          cb(tok);
        } catch (ex:Error) {
          trace("qiniu-token parse failed: " + ex.message);
          cb("");
        }
      });
      loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void {
        trace("qiniu-token request failed: " + e.text);
        cb("");
      });
      loader.load(req);
    }

    private function queryUploadHost(uploadToken:String, cb:Function):void {
      var ak:String = uploadToken;
      const idx:int = uploadToken.indexOf(":");
      if (idx >= 0) ak = uploadToken.substring(0, idx);
      const url:String = "https://api.qiniu.com/v4/query?ak=" + encodeURIComponent(ak) + "&bucket=" + encodeURIComponent(BUCKET);

      const req:URLRequest = new URLRequest(url);
      req.method = URLRequestMethod.GET;

      const loader:URLLoader = new URLLoader();
      loader.dataFormat = URLLoaderDataFormat.TEXT;
      loader.addEventListener(Event.COMPLETE, function(e:Event):void {
        try {
          const obj:Object = JSON.parse(String(loader.data));
          var h:String = "";
          if (obj && obj.domains && obj.domains.length > 0) {
            h = String(obj.domains[0]);
            h = h.replace(/^https?:\/\//, "");
            h = h.replace(/\/.*$/, "");
          }
          cb(h && h.length > 0 ? h : DEFAULT_UPLOAD_HOST);
        } catch (ex:Error) {
          cb(DEFAULT_UPLOAD_HOST);
        }
      });
      loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void {
        cb(DEFAULT_UPLOAD_HOST);
      });
      loader.load(req);
    }

    private function uploadOnce(uploadUrl:String, uploadToken:String, key:String, fileBytes:ByteArray, mimeType:String, cb:Function):void {
      const mp:MultipartFormData = new MultipartFormData();
      mp.addField("token", uploadToken);
      mp.addField("key", key);
      mp.addFile("file", key, fileBytes, mimeType);
      mp.finish();

      const req:URLRequest = new URLRequest(uploadUrl);
      req.method = URLRequestMethod.POST;
      req.data = mp.body;
      req.contentType = "multipart/form-data; boundary=" + mp.boundary;
      req.requestHeaders = [ new URLRequestHeader("User-Agent", "QiniuDart") ];

      const loader:URLLoader = new URLLoader();
      loader.dataFormat = URLLoaderDataFormat.TEXT;
      loader.addEventListener(Event.COMPLETE, function(e:Event):void {
        // URLLoader doesn't expose status reliably in all runtimes; keep body.
        cb(200, String(loader.data));
      });
      loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void {
        cb(0, e.text);
      });

      try {
        loader.load(req);
      } catch (ex:Error) {
        cb(0, ex.message);
      }
    }
  }
}

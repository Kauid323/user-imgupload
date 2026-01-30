package {
  import flash.display.Sprite;
  import flash.net.URLRequest;
  import flash.net.URLRequestMethod;
  import flash.net.URLLoader;
  import flash.net.URLLoaderDataFormat;
  import flash.net.URLVariables;
  import flash.events.Event;
  import flash.events.IOErrorEvent;

  public class Main extends Sprite {
    // Config
    private var USER_TOKEN:String = "";
    private var ENABLE_WEBP:Boolean = false;
    private var WEBP_QUALITY:int = 95;
    private var BUCKET:String = "chat68";
    private var TOKEN_URL:String = "https://chat-go.jwzhd.com/v1/misc/qiniu-token";
    private var DEFAULT_UPLOAD_HOST:String = "upload-z2.qiniup.com";

    public function Main() {
      // Entry (skeleton):
      // 1) Read input path/url (AIR FileReference or text input)
      // 2) Load bytes (URLLoader for URL, FileStream for local)
      // 3) Optional WebP (requires native extension or external tool)
      // 4) MD5 key
      // 5) GET TOKEN_URL with header token: USER_TOKEN
      // 6) Query upload host
      // 7) multipart/form-data upload

      if (USER_TOKEN.length == 0) {
        trace("user_token empty");
        return;
      }

      getQiniuToken();
    }

    private function getQiniuToken():void {
      var req:URLRequest = new URLRequest(TOKEN_URL);
      req.method = URLRequestMethod.GET;
      req.requestHeaders = [ new flash.net.URLRequestHeader("token", USER_TOKEN), new flash.net.URLRequestHeader("Content-Type", "application/json") ];

      var loader:URLLoader = new URLLoader();
      loader.dataFormat = URLLoaderDataFormat.TEXT;
      loader.addEventListener(Event.COMPLETE, function(e:Event):void {
        trace("token resp: " + loader.data);
        // TODO parse JSON and read data.token
      });
      loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent):void {
        trace("token request failed: " + e.text);
      });
      loader.load(req);
    }
  }
}

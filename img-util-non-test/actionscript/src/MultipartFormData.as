package {
  import flash.utils.ByteArray;

  public class MultipartFormData {
    public var boundary:String;
    public var body:ByteArray;

    public function MultipartFormData() {
      boundary = "----imgutil" + new Date().time + "_" + int(Math.random() * 1000000);
      body = new ByteArray();
    }

    private function writeString(s:String):void {
      body.writeUTFBytes(s);
    }

    public function addField(name:String, value:String):void {
      writeString("--" + boundary + "\r\n");
      writeString("Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n");
      writeString(value);
      writeString("\r\n");
    }

    public function addFile(name:String, filename:String, bytes:ByteArray, contentType:String):void {
      writeString("--" + boundary + "\r\n");
      writeString("Content-Disposition: form-data; name=\"" + name + "\"; filename=\"" + filename + "\"\r\n");
      writeString("Content-Type: " + contentType + "\r\n\r\n");
      body.writeBytes(bytes);
      writeString("\r\n");
    }

    public function finish():void {
      writeString("--" + boundary + "--\r\n");
      body.position = 0;
    }
  }
}

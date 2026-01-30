codeunit 50100 ImgUtil
{
    procedure Upload(PathOrUrl: Text; UserToken: Text; Bucket: Text; TokenUrl: Text)
    var
        UploadToken: Text;
        Host: Text;
        UploadUrl: Text;
        Key: Text;
        RespText: Text;
    begin
        UploadToken := GetQiniuToken(UserToken, TokenUrl);
        if UploadToken = '' then
            Error('qiniu-token failed');

        Host := QueryUploadHost(UploadToken, Bucket);
        if Host = '' then
            Host := 'upload-z2.qiniup.com';
        UploadUrl := 'https://' + Host;

        // NOTE: For brevity, this AL version does not implement URL download / WebP / MD5.
        // You can pass a precomputed key and file bytes to UploadOnce.
        Key := 'md5.bin';

        RespText := UploadOnce(UploadUrl, UploadToken, Key, PathOrUrl, 'application/octet-stream');
        Message(RespText);
    end;

    local procedure GetQiniuToken(UserToken: Text; TokenUrl: Text): Text
    var
        Client: HttpClient;
        Request: HttpRequestMessage;
        Response: HttpResponseMessage;
        Headers: HttpHeaders;
        Body: Text;
        Json: JsonObject;
        CodeTok: JsonToken;
        DataObj: JsonObject;
        Tok: Text;
    begin
        Request.SetRequestUri(TokenUrl);
        Request.Method('GET');
        Headers := Request.GetHeaders();
        Headers.Add('token', UserToken);
        Headers.Add('Content-Type', 'application/json');

        Client.Send(Request, Response);
        Response.Content().ReadAs(Body);

        if (Response.HttpStatusCode < 200) or (Response.HttpStatusCode >= 300) then
            exit('');

        if not Json.ReadFrom(Body) then
            exit('');

        if not Json.Get('code', CodeTok) then
            exit('');
        if CodeTok.AsValue().AsInteger() <> 1 then
            exit('');

        if Json.Get('data', CodeTok) and CodeTok.IsObject() then begin
            DataObj := CodeTok.AsObject();
            if DataObj.Get('token', CodeTok) then
                Tok := CodeTok.AsValue().AsText();
        end;

        if Tok = '' then
            if Json.Get('token', CodeTok) then
                Tok := CodeTok.AsValue().AsText();

        exit(Tok);
    end;

    local procedure QueryUploadHost(UploadToken: Text; Bucket: Text): Text
    var
        Client: HttpClient;
        Request: HttpRequestMessage;
        Response: HttpResponseMessage;
        Body: Text;
        Ak: Text;
        Url: Text;
        Json: JsonObject;
        Tok: JsonToken;
        Arr: JsonArray;
        Host: Text;
    begin
        Ak := UploadToken;
        if StrPos(Ak, ':') > 0 then
            Ak := CopyStr(Ak, 1, StrPos(Ak, ':') - 1);

        Url := 'https://api.qiniu.com/v4/query?ak=' + Ak + '&bucket=' + Bucket;
        Request.SetRequestUri(Url);
        Request.Method('GET');
        Client.Send(Request, Response);
        Response.Content().ReadAs(Body);
        if (Response.HttpStatusCode < 200) or (Response.HttpStatusCode >= 300) then
            exit('upload-z2.qiniup.com');
        if not Json.ReadFrom(Body) then
            exit('upload-z2.qiniup.com');

        if Json.Get('domains', Tok) and Tok.IsArray() then begin
            Arr := Tok.AsArray();
            if Arr.Count() > 0 then begin
                Tok := Arr.Get(0);
                Host := Tok.AsValue().AsText();
                Host := DelStr(Host, 1, StrLen('https://'));
                exit(Host);
            end;
        end;

        exit('upload-z2.qiniup.com');
    end;

    local procedure UploadOnce(UploadUrl: Text; UploadToken: Text; Key: Text; LocalPath: Text; MimeType: Text): Text
    var
        Client: HttpClient;
        Request: HttpRequestMessage;
        Response: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        Boundary: Text;
        TempBlob: Codeunit "Temp Blob";
        OutS: OutStream;
        InS: InStream;
        BodyText: Text;
        FileInS: InStream;
    begin
        Boundary := '----imgutil' + Format(CreateGuid());

        TempBlob.CreateOutStream(OutS);
        OutS.WriteText('--' + Boundary + '\r\n');
        OutS.WriteText('Content-Disposition: form-data; name="token"\r\n\r\n');
        OutS.WriteText(UploadToken + '\r\n');

        OutS.WriteText('--' + Boundary + '\r\n');
        OutS.WriteText('Content-Disposition: form-data; name="key"\r\n\r\n');
        OutS.WriteText(Key + '\r\n');

        OutS.WriteText('--' + Boundary + '\r\n');
        OutS.WriteText('Content-Disposition: form-data; name="file"; filename="' + Key + '"\r\n');
        OutS.WriteText('Content-Type: ' + MimeType + '\r\n\r\n');

        // Local file reading depends on extension libraries / platform.
        // This is a placeholder: you should supply an InStream of the file bytes.
        // For example, use File Management codeunit to open LocalPath into FileInS.
        // OutS.CopyFrom(FileInS);

        OutS.WriteText('\r\n');
        OutS.WriteText('--' + Boundary + '--\r\n');

        TempBlob.CreateInStream(InS);
        Content.WriteFrom(InS);
        Headers := Content.GetHeaders();
        Headers.Remove('Content-Type');
        Headers.Add('Content-Type', 'multipart/form-data; boundary=' + Boundary);

        Request.SetRequestUri(UploadUrl);
        Request.Method('POST');
        Request.Content := Content;

        Client.Send(Request, Response);
        Response.Content().ReadAs(BodyText);
        exit(BodyText);
    end;
}

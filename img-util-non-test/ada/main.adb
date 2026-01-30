with Ada.Text_IO; use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.Calendar;
with GNAT.OS_Lib;

procedure Main is
  Default_Upload_Host : constant String := "upload-z2.qiniup.com";

  function Trim_S (S : String) return String is
    use Ada.Strings.Fixed;
  begin
    return Trim (S, Ada.Strings.Both);
  end Trim_S;

  function Env (K : String) return String is
    V : GNAT.OS_Lib.String_Access := GNAT.OS_Lib.Getenv (K);
  begin
    if V = null then
      return "";
    else
      declare
        S : constant String := V.all;
      begin
        GNAT.OS_Lib.Free (V);
        return S;
      end;
    end if;
  end Env;

  function Debug_Enabled return Boolean is
    V : constant String := Env ("IMGUTIL_DEBUG");
  begin
    return V'Length > 0 and then V /= "0";
  end Debug_Enabled;

  procedure Debug_Log (Msg : String) is
  begin
    if Debug_Enabled then
      Put_Line (Standard_Error, "[debug] " & Msg);
    end if;
  end Debug_Log;

  procedure Die (Msg : String) is
  begin
    Put_Line (Standard_Error, Msg);
    raise Program_Error;
  end Die;

  function Sh_Capture (Cmd : String) return String is
    Tmp  : constant String := Ada.Directories.Temporary_Directory & "imgutil_" & Integer'Image (Integer (Ada.Calendar.Seconds (Ada.Calendar.Clock))) & ".out";
    Ok   : Boolean := False;
    Args : GNAT.OS_Lib.Argument_List (1 .. 3);
    Full : constant String := "sh";
  begin
    Args (1) := new String'("-c");
    Args (2) := new String'(Cmd & " > """ & Tmp & """ 2>&1");
    Args (3) := new String'(" ");

    GNAT.OS_Lib.Spawn (Full, Args, Ok);

    for I in Args'Range loop
      GNAT.OS_Lib.Free (Args (I));
    end loop;

    if not Ok then
      return "";
    end if;

    declare
      F : File_Type;
      S : Unbounded_String := To_Unbounded_String ("");
    begin
      Open (F, In_File, Tmp);
      while not End_Of_File (F) loop
        declare
          L : constant String := Get_Line (F);
        begin
          S := S & To_Unbounded_String (L) & To_Unbounded_String (Ada.Characters.Latin_1.LF);
        end;
      end loop;
      Close (F);
      Ada.Directories.Delete_File (Tmp);
      return To_String (S);
    exception
      when others =>
        begin
          Ada.Directories.Delete_File (Tmp);
        exception
          when others => null;
        end;
        return "";
    end;
  end Sh_Capture;

  function Sh_Exit_Code (Cmd : String) return Integer is
    Ok   : Boolean := False;
    Args : GNAT.OS_Lib.Argument_List (1 .. 2);
  begin
    Args (1) := new String'("-c");
    Args (2) := new String'(Cmd);
    GNAT.OS_Lib.Spawn ("sh", Args, Ok);
    for I in Args'Range loop
      GNAT.OS_Lib.Free (Args (I));
    end loop;
    return (if Ok then 0 else 1);
  end Sh_Exit_Code;

  function Is_Url (S : String) return Boolean is
  begin
    return S'Length >= 7 and then (S (S'First .. S'First + 6) = "http://")
      or else (S'Length >= 8 and then S (S'First .. S'First + 7) = "https://");
  end Is_Url;

  function Jq_Get (Key, Def : String) return String is
    V : constant String := Trim_S (Sh_Capture ("jq -r '." & Key & " // empty' config.json"));
  begin
    if V'Length = 0 then
      return Def;
    else
      return V;
    end if;
  end Jq_Get;

  function Get_Token (User_Token, Token_Url : String) return String is
    Resp : constant String := Sh_Capture (
      "curl -sS """ & Token_Url & """ -H ""token: " & User_Token & """ -H ""Content-Type: application/json""");
    Tok  : constant String := Trim_S (Sh_Capture (
      "printf %s """ & Resp & """ | jq -r '.data.token // .token // empty'"));
  begin
    if Debug_Enabled then
      Debug_Log ("qiniu-token resp=" & Resp);
    end if;
    return Tok;
  end Get_Token;

  function Query_Host (Upload_Token, Bucket : String) return String is
    Ak  : constant String := Trim_S (Sh_Capture ("printf %s """ & Upload_Token & """ | sed -E 's/:.*$//'"));
    Url : constant String := "https://api.qiniu.com/v4/query?ak=" & Ak & "&bucket=" & Bucket;
    Resp : constant String := Sh_Capture ("curl -sS """ & Url & """" );
    Host : constant String := Trim_S (Sh_Capture ("printf %s """ & Resp & """ | jq -r '.domains[0] // empty'"));
  begin
    if Host'Length = 0 then
      return Default_Upload_Host;
    else
      return Host;
    end if;
  exception
    when others =>
      return Default_Upload_Host;
  end Query_Host;

  function Md5_File (Path : String) return String is
    V : constant String := Trim_S (Sh_Capture (
      "(command -v md5sum >/dev/null 2>&1 && md5sum """ & Path & """ | awk '{print $1}') || (command -v md5 >/dev/null 2>&1 && md5 -q """ & Path & """ )"));
  begin
    return V;
  end Md5_File;

  function Basename_Ext (Path : String) return String is
    V : constant String := Trim_S (Sh_Capture ("basename """ & Path & """ | sed -nE 's/.*\\.([^.]+)$/\\1/p'"));
  begin
    if V'Length = 0 then
      return "bin";
    else
      return V;
    end if;
  end Basename_Ext;

  function To_Webp (Src, Dst : String; Q : Integer) return Boolean is
    Cmd : constant String := "cwebp -q " & Integer'Image (Q) & " """ & Src & """ -o """ & Dst & """ >/dev/null 2>&1";
  begin
    return Sh_Exit_Code (Cmd) = 0;
  end To_Webp;

  function Upload (Upload_Url, Token, Key, File_Path : String) return String is
  begin
    return Sh_Capture (
      "curl -sS """ & Upload_Url & """ -F ""token=" & Token & """ -F ""key=" & Key & """ -F ""file=@" & File_Path & """" );
  end Upload;

  function Pretty (Raw : String) return String is
  begin
    return Sh_Capture ("printf %s """ & Raw & """ | (command -v jq >/dev/null 2>&1 && jq . || cat)" );
  end Pretty;

  function Read_Line_Prompt (Prompt : String) return String is
  begin
    Put (Prompt);
    return Get_Line;
  end Read_Line_Prompt;

  Input : String := "";
begin
  if Sh_Exit_Code ("command -v curl >/dev/null 2>&1") /= 0 then
    Die ("curl not found");
  end if;
  if Sh_Exit_Code ("command -v jq >/dev/null 2>&1") /= 0 then
    Die ("jq not found (required for Ada version)");
  end if;
  if Sh_Exit_Code ("test -f config.json") /= 0 then
    Die ("config.json not found");
  end if;

  declare
    User_Token  : constant String := Jq_Get ("user_token", "");
    Enable_Webp : constant String := Jq_Get ("enable_webp", "false");
    Webp_Q_Str  : constant String := Jq_Get ("webp_quality", "95");
    Bucket      : constant String := Jq_Get ("bucket", "chat68");
    Token_Url   : constant String := Jq_Get ("qiniu_token_url", "https://chat-go.jwzhd.com/v1/misc/qiniu-token");
    Webp_Q      : Integer := 95;
  begin
    if User_Token'Length = 0 then
      Die ("config.json里的 user_token 为空");
    end if;
    begin
      Webp_Q := Integer'Value (Trim_S (Webp_Q_Str));
    exception
      when others => Webp_Q := 95;
    end;

    if Ada.Command_Line.Argument_Count >= 1 then
      Input := Ada.Command_Line.Argument (1);
    else
      Input := Read_Line_Prompt ("请输入图片地址(本地路径或URL): ");
    end if;
    Input := Trim_S (Input);
    if Input'Length = 0 then
      Die ("未输入图片地址");
    end if;

    declare
      Tmp_Dir : constant String := Ada.Directories.Temporary_Directory;
      T       : constant String := Integer'Image (Integer (Ada.Calendar.Seconds (Ada.Calendar.Clock)));
      Dl_Path : constant String := Tmp_Dir & "imgutil_" & T & ".bin";
      Src_Path : String := Input;
    begin
      if Is_Url (Input) then
        if Sh_Exit_Code ("curl -L -sS """ & Input & """ -o """ & Dl_Path & """" ) /= 0 then
          Die ("上传失败: download failed");
        end if;
        Src_Path := Dl_Path;
      end if;

      if Sh_Exit_Code ("test -f """ & Src_Path & """" ) /= 0 then
        Die ("上传失败: could not read file");
      end if;

      declare
        Up_Path : String := Src_Path;
        Ext     : String := Basename_Ext (Src_Path);
      begin
        if Enable_Webp = "true" then
          if Sh_Exit_Code ("command -v cwebp >/dev/null 2>&1") /= 0 then
            Die ("上传失败: cwebp failed (install cwebp or set enable_webp=false)");
          end if;
          declare
            Out_Path : constant String := Tmp_Dir & "imgutil_" & T & ".webp";
          begin
            if not To_Webp (Src_Path, Out_Path, Webp_Q) then
              Die ("上传失败: cwebp failed (install cwebp or set enable_webp=false)");
            end if;
            Up_Path := Out_Path;
            Ext := "webp";
          end;
        end if;

        declare
          Md5 : constant String := Md5_File (Up_Path);
        begin
          if Md5'Length = 0 then
            Die ("md5 tool not found (need md5sum or md5)");
          end if;
          declare
            Key : constant String := Md5 & "." & Ext;
            Upload_Token : constant String := Get_Token (User_Token, Token_Url);
          begin
            if Upload_Token'Length = 0 then
              Die ("上传失败: qiniu-token failed");
            end if;
            declare
              Host : constant String := Query_Host (Upload_Token, Bucket);
              Url  : String := "https://" & Host;
              Resp : String := Upload (Url, Upload_Token, Key, Up_Path);
            begin
              if Resp'Length = 0 then
                Die ("上传失败: qiniu upload failed");
              end if;
              if Ada.Strings.Fixed.Index (Resp, "no such domain") /= 0 then
                Url := "https://" & Default_Upload_Host;
                Resp := Upload (Url, Upload_Token, Key, Up_Path);
              end if;
              Put_Line ("上传成功");
              Put_Line ("response_json:");
              Put_Line (Pretty (Resp));
            end;
          end;
        end;
      end;
    end;
  end;
exception
  when Program_Error =>
    return;
end Main;

REPORT zimgutil_upload.

" NOTE:
" - This is a near-runnable ABAP outline intended for an SAP system.
" - Requires HTTP client (CL_HTTP_CLIENT) and JSON parser (/UI2/CL_JSON).
" - File IO (local path) depends on your environment (frontend upload or app server).

CONSTANTS: gc_default_upload_host TYPE string VALUE 'upload-z2.qiniup.com'.

PARAMETERS:
  p_input TYPE string LOWER CASE OBLIGATORY,
  p_token TYPE string LOWER CASE OBLIGATORY,
  p_bucket TYPE string LOWER CASE DEFAULT 'chat68',
  p_turl  TYPE string LOWER CASE DEFAULT 'https://chat-go.jwzhd.com/v1/misc/qiniu-token'.

TYPES: BEGIN OF ty_token_data,
         token TYPE string,
       END OF ty_token_data.

TYPES: BEGIN OF ty_token_resp,
         code TYPE i,
         data TYPE ty_token_data,
         token TYPE string,
       END OF ty_token_resp.

TYPES: BEGIN OF ty_query_resp,
         domains TYPE STANDARD TABLE OF string WITH DEFAULT KEY,
       END OF ty_query_resp.

CLASS lcl_imgutil DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS:
      get_upload_token
        IMPORTING iv_user_token TYPE string iv_token_url TYPE string
        RETURNING VALUE(rv_upload_token) TYPE string,
      query_upload_host
        IMPORTING iv_upload_token TYPE string iv_bucket TYPE string
        RETURNING VALUE(rv_host) TYPE string,
      upload_multipart
        IMPORTING iv_upload_url TYPE string iv_upload_token TYPE string iv_key TYPE string
                  iv_file_bytes TYPE xstring iv_mime TYPE string
        RETURNING VALUE(rv_body) TYPE string.
  PRIVATE SECTION.
    CLASS-METHODS http_get
      IMPORTING iv_url TYPE string it_headers TYPE tihttpnvp OPTIONAL
      EXPORTING ev_status TYPE i ev_body TYPE string.
    CLASS-METHODS http_post
      IMPORTING iv_url TYPE string it_headers TYPE tihttpnvp OPTIONAL iv_body_x TYPE xstring
      EXPORTING ev_status TYPE i ev_body TYPE string.
ENDCLASS.

CLASS lcl_imgutil IMPLEMENTATION.
  METHOD http_get.
    DATA: lo_client TYPE REF TO if_http_client.
    cl_http_client=>create_by_url( EXPORTING url = iv_url IMPORTING client = lo_client ).
    lo_client->request->set_method( if_http_request=>co_request_method_get ).
    LOOP AT it_headers ASSIGNING FIELD-SYMBOL(<h>).
      lo_client->request->set_header_field( name = <h>-name value = <h>-value ).
    ENDLOOP.
    lo_client->send( ).
    lo_client->receive( ).
    ev_status = lo_client->response->get_status( ).
    ev_body = lo_client->response->get_cdata( ).
  ENDMETHOD.

  METHOD http_post.
    DATA: lo_client TYPE REF TO if_http_client.
    cl_http_client=>create_by_url( EXPORTING url = iv_url IMPORTING client = lo_client ).
    lo_client->request->set_method( if_http_request=>co_request_method_post ).
    LOOP AT it_headers ASSIGNING FIELD-SYMBOL(<h>).
      lo_client->request->set_header_field( name = <h>-name value = <h>-value ).
    ENDLOOP.
    lo_client->request->set_data( iv_body_x ).
    lo_client->send( ).
    lo_client->receive( ).
    ev_status = lo_client->response->get_status( ).
    ev_body = lo_client->response->get_cdata( ).
  ENDMETHOD.

  METHOD get_upload_token.
    DATA: lt_headers TYPE tihttpnvp,
          lv_status  TYPE i,
          lv_body    TYPE string,
          ls_resp    TYPE ty_token_resp.

    APPEND VALUE #( name = 'token' value = iv_user_token ) TO lt_headers.
    APPEND VALUE #( name = 'Content-Type' value = 'application/json' ) TO lt_headers.
    http_get( EXPORTING iv_url = iv_token_url it_headers = lt_headers IMPORTING ev_status = lv_status ev_body = lv_body ).
    IF lv_status < 200 OR lv_status >= 300.
      RETURN.
    ENDIF.

    /ui2/cl_json=>deserialize( EXPORTING json = lv_body CHANGING data = ls_resp ).
    IF ls_resp-code <> 1.
      RETURN.
    ENDIF.
    IF ls_resp-data-token IS NOT INITIAL.
      rv_upload_token = ls_resp-data-token.
    ELSEIF ls_resp-token IS NOT INITIAL.
      rv_upload_token = ls_resp-token.
    ENDIF.
  ENDMETHOD.

  METHOD query_upload_host.
    DATA: lv_ak TYPE string,
          lv_url TYPE string,
          lv_status TYPE i,
          lv_body TYPE string,
          ls_resp TYPE ty_query_resp.

    lv_ak = iv_upload_token.
    SPLIT lv_ak AT ':' INTO lv_ak DATA(dummy).
    lv_url = |https://api.qiniu.com/v4/query?ak={ lv_ak }&bucket={ iv_bucket }|.
    http_get( EXPORTING iv_url = lv_url IMPORTING ev_status = lv_status ev_body = lv_body ).
    IF lv_status < 200 OR lv_status >= 300.
      rv_host = gc_default_upload_host.
      RETURN.
    ENDIF.

    TRY.
        /ui2/cl_json=>deserialize( EXPORTING json = lv_body CHANGING data = ls_resp ).
        READ TABLE ls_resp-domains INDEX 1 INTO rv_host.
        IF rv_host IS INITIAL.
          rv_host = gc_default_upload_host.
        ELSE.
          REPLACE REGEX '^https?://|/.*$' IN rv_host WITH ''.
        ENDIF.
      CATCH cx_root.
        rv_host = gc_default_upload_host.
    ENDTRY.
  ENDMETHOD.

  METHOD upload_multipart.
    DATA: lv_boundary TYPE string VALUE '----imgutil_abap',
          lv_status TYPE i,
          lv_body TYPE string,
          lt_headers TYPE tihttpnvp,
          lv_p1 TYPE string,
          lv_p2 TYPE string,
          lx_body TYPE xstring.

    lv_boundary = |----imgutil{ sy-uzeit }{ sy-index }|.

    lv_p1 = |--{ lv_boundary }\r\n| &&
            |Content-Disposition: form-data; name="token"\r\n\r\n| &&
            |{ iv_upload_token }\r\n| &&
            |--{ lv_boundary }\r\n| &&
            |Content-Disposition: form-data; name="key"\r\n\r\n| &&
            |{ iv_key }\r\n| &&
            |--{ lv_boundary }\r\n| &&
            |Content-Disposition: form-data; name="file"; filename="{ iv_key }"\r\n| &&
            |Content-Type: { iv_mime }\r\n\r\n|.

    lv_p2 = |\r\n--{ lv_boundary }--\r\n|.

    lx_body = cl_abap_codepage=>convert_to( lv_p1 ).
    lx_body = lx_body && iv_file_bytes && cl_abap_codepage=>convert_to( lv_p2 ).

    APPEND VALUE #( name = 'Content-Type' value = |multipart/form-data; boundary={ lv_boundary }| ) TO lt_headers.
    APPEND VALUE #( name = 'User-Agent' value = 'QiniuDart' ) TO lt_headers.

    http_post( EXPORTING iv_url = iv_upload_url it_headers = lt_headers iv_body_x = lx_body
               IMPORTING ev_status = lv_status ev_body = lv_body ).

    rv_body = lv_body.
  ENDMETHOD.
ENDCLASS.

START-OF-SELECTION.
  DATA: lv_token TYPE string,
        lv_host TYPE string,
        lv_upload_url TYPE string,
        lv_key TYPE string VALUE 'md5.bin',
        lv_resp TYPE string,
        lx_file TYPE xstring.

  lv_token = lcl_imgutil=>get_upload_token( iv_user_token = p_token iv_token_url = p_turl ).
  IF lv_token IS INITIAL.
    WRITE: / '上传失败: qiniu-token failed'.
    RETURN.
  ENDIF.

  lv_host = lcl_imgutil=>query_upload_host( iv_upload_token = lv_token iv_bucket = p_bucket ).
  lv_upload_url = |https://{ lv_host }|.

  " File bytes reading is environment-specific and omitted.
  " Set lx_file to the binary bytes you want to upload.
  lx_file = cl_abap_codepage=>convert_to( 'dummy' ).

  lv_resp = lcl_imgutil=>upload_multipart(
    iv_upload_url = lv_upload_url
    iv_upload_token = lv_token
    iv_key = lv_key
    iv_file_bytes = lx_file
    iv_mime = 'application/octet-stream' ).

  WRITE: / '上传完成:', / lv_resp.

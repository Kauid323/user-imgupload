package com.example.imgutil;

interface IImgUploader {
  String upload(in String pathOrUrl,
                in String userToken,
                in boolean enableWebp,
                in int webpQuality,
                in String bucket,
                in String qiniuTokenUrl);
}

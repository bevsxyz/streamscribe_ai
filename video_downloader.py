#!/usr/bin/env python3

import argparse
import os
import json
import tempfile
from yt_dlp import YoutubeDL
import boto3
from botocore.exceptions import ClientError

def upload_fileobj_to_s3(fileobj, bucket, key):
    s3_client = boto3.client('s3')
    try:
        s3_client.upload_fileobj(fileobj, bucket, key)
        return True
    except ClientError as e:
        print(f"Error uploading to S3: {e}")
        return False

def process_video(url, bucket_name, prefix=''):
    with tempfile.TemporaryDirectory() as temp_dir:
        # Options for downloading
        ydl_opts = {
            'outtmpl': os.path.join(temp_dir, '%(id)s.%(ext)s'),
            'quiet': True,
            'format': 'worstvideo+worstaudio/worst',  # Download best video and audio
            'merge_output_format': 'mp4',  # Merging to mp4 format
            'verbose': True,
            'postprocessors': [
                {
                    'key': 'FFmpegVideoMerge',  # Use this for merging video and audio
                },
                {
                'key': 'FFmpegExtractAudio',
                'preferredcodec': 'mp3',
                'preferredquality': '192',
            }],
            'writethumbnail': True,  # Optional: Download thumbnail
            'writeinfojson': True,  # Optional: Download metadata
        }
        
        # Download video (this will also extract audio due to postprocessor)
        with YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            video_filename = ydl.prepare_filename(info)
            audio_filename = os.path.splitext(video_filename)[0] + '.mp3'
        
        # Prepare metadata
        metadata = {
            'title': info.get('title'),
            'description': info.get('description'),
            'upload_date': info.get('upload_date'),
            'uploader': info.get('uploader'),
            'duration': info.get('duration'),
            'view_count': info.get('view_count'),
            'like_count': info.get('like_count'),
            'comment_count': info.get('comment_count'),
        }
        
        video_id = info['id']
        
        # Upload video
        with open(video_filename, 'rb') as f:
            upload_fileobj_to_s3(f, bucket_name, f'{prefix}{video_id}.mp4')
        
        # Upload audio
        with open(audio_filename, 'rb') as f:
            upload_fileobj_to_s3(f, bucket_name, f'{prefix}{video_id}.mp3')
        
        # Upload metadata
        metadata_json = json.dumps(metadata, indent=2)
        upload_fileobj_to_s3(
            fileobj=metadata_json.encode('utf-8'),
            bucket=bucket_name,
            key=f'{prefix}{video_id}_metadata.json'
        )

def main():
    parser = argparse.ArgumentParser(description="Download video and upload to S3")
    
    # Add arguments
    parser.add_argument("url", type=str, help="The URL of the video to download")
    parser.add_argument("bucket_name", type=str, help="The name of the S3 bucket to upload to")
    parser.add_argument("--prefix", type=str, default="videos/", help="Optional S3 key prefix (default: 'videos/')")

    # Parse the arguments
    args = parser.parse_args()

    # Access parsed arguments
    url = args.url
    bucket_name = args.bucket_name
    prefix = args.prefix
    
    process_video(url, bucket_name, prefix)

if __name__ == '__main__':
    main()
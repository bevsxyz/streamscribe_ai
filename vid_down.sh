#!/bin/bash

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <YouTube URL> <S3 bucket> [prefix]"
    echo "Example: $0 https://youtube.com/watch?v=12345 my-bucket videos/"
    exit 1
fi

URL="$1"
BUCKET="${2:-streamscribe-data-bucket}"
PREFIX="${3:-video}" # Optional prefix, empty if not provided

# Use yt-dlp to get the video ID
VIDEO_ID=$(yt-dlp --get-id "$URL")

# Ensure VIDEO_ID was obtained
if [ -z "$VIDEO_ID" ]; then
    echo "Failed to get video ID"
    exit 1
fi

echo "Downloading content for video ID: $VIDEO_ID"

# Download separate video and audio streams and merge
echo "Downloading separate streams and performing merge..."
yt-dlp -f "wv,wa" \
    --write-subs \
    --write-thumbnail \
    --convert-thumbnails jpg \
    -o "${VIDEO_ID}.%(ext)s" \
    "$URL"

# Download best quality video+audio directly
echo "Downloading best quality video+audio..."
yt-dlp -f "wv*+ba/b" \
    --merge-output-format mp4 \
    -o "${VIDEO_ID}_full.%(ext)s" \
    "$URL"

# Download best audio and convert to mp3
echo "Downloading audio..."
yt-dlp -f "ba" \
    -x --audio-format mp3 \
    -o "${VIDEO_ID}_audio.%(ext)s" \
    "$URL"

# Download metadata as JSON
echo "Downloading metadata..."
yt-dlp -J "$URL" > "${VIDEO_ID}_metadata.json"

echo "Download completed. Files:"
ls -l ${VIDEO_ID}*

echo "
File descriptions:
${VIDEO_ID}.mp4          - Merged video from separate streams
${VIDEO_ID}_full.mp4     - Directly downloaded best quality video
${VIDEO_ID}_audio.mp3    - Audio-only file
${VIDEO_ID}.jpg          - Thumbnail image
${VIDEO_ID}_metadata.json - Metadata in JSON format
${VIDEO_ID}*.vtt                    - Subtitles (if available)"

echo "Uploading all files to S3..."
# Upload all files that start with VIDEO_ID to S3
aws s3 cp . "s3://${BUCKET}/${PREFIX}/${VIDEO_ID}" \
    --recursive \
    --exclude "*" \
    --include "${VIDEO_ID}*"

echo "Updating CSV file with object keys..."
# Append all S3 keys and local file paths to a CSV file
for file in ${VIDEO_ID}*; do
    S3_KEY="${PREFIX}/${VIDEO_ID}/${file}"
    echo "${VIDEO_ID},${S3_KEY},${file}" >> uploaded_files.csv
done

echo "Cleanup starting..."
# Cleanup local files
rm -f ${VIDEO_ID}*

echo "Process completed!"
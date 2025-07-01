import streamlit as st
import boto3
import logging
import pandas as pd
import openai
import base64
from botocore.exceptions import NoCredentialsError
import subprocess
import asyncio

# Add Spark imports
from pyspark.sql import SparkSession

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Function to run the bash script asynchronously
async def run_bash_script(url):
    process = await asyncio.create_subprocess_exec(
        '/opt/streamscribe/vid_down.sh', url,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    stdout, stderr = await process.communicate()
    if process.returncode == 0:
        return stdout.decode()
    else:
        return stderr.decode()

def handle_vimeo_url():
    vimeo_url = st.text_input("Enter Vimeo Video URL:")
    if vimeo_url:
        with st.spinner("Downloading video..."):
            result = asyncio.run(run_bash_script(vimeo_url))
            st.text(result)
            st.rerun()

class S3VideoStreamer:
    def __init__(self):
        self.s3_bucket = st.secrets["aws"]["S3_BUCKET_NAME"]
        self.s3_client = boto3.client('s3')
        self.vtt_content = ""
        self.initialize_openai()
        # Initialize Spark session and table name
        self.spark = SparkSession.builder.appName("StreamlitApp").getOrCreate()
        self.table_name = "default.uploaded_files_catalog"

    def initialize_openai(self):
        try:
            openai.api_key = st.secrets["general"]["OPENAI_API_KEY"]
        except KeyError:
            st.error("Please set your OpenAI API key in Streamlit secrets.")
            st.stop()
        
    # Replace CSV loader with Spark table loader
    def load_catalog_table(self):
        try:
            spark_df = self.spark.read.table(self.table_name)
            return spark_df.toPandas()
        except Exception as e:
            st.error(f"Failed to load Spark table: {str(e)}")
            return None

    def get_presigned_url(self, s3_key):
        try:
            url = self.s3_client.generate_presigned_url(
                'get_object',
                Params={'Bucket': self.s3_bucket, 'Key': s3_key},
                ExpiresIn=3600
            )
            return url
        except NoCredentialsError:
            st.error("AWS credentials not found.")
            return None
        except Exception as e:
            st.error(f"Error generating pre-signed URL: {str(e)}")
            return None
    
    def process_chat_query(self, query, with_frame=False):
        try:
            context = self.vtt_content
            if not with_frame:
                response = openai.ChatCompletion.create(
                    model="gpt-4-turbo-preview",
                    messages=[{
                        "role": "system",
                        "content": "You are a helpful assistant analyzing video content. Provide clear and concise responses."
                    },
                    {
                        "role": "user",
                        "content": f"Video context: {context}\n\nQuestion: {query}"
                    }],
                    max_tokens=500
                )
            if response and response.choices and len(response.choices) > 0:
                return response.choices[0].message.content
            else:
                return "Sorry, I couldn't generate a response. Please try again."
        except openai.OpenAIError as e:
            logger.error(f"OpenAI API error: {e}")
            return f"OpenAI API error: {str(e)}"
        except Exception as e:
            logger.error(f"Query processing error: {e}")
            return f"Failed to process query: {str(e)}"

    def display_chat(self):
        st.subheader("Chat")
        if "messages" not in st.session_state:
            st.session_state.messages = []
        chat_container = st.container()
        with chat_container:
            prompt = st.chat_input("Ask about the video...")
            chat_history = st.empty()
            chat_history.markdown("<div style='height: 300px; overflow-y: scroll;'>", unsafe_allow_html=True)
            for message in st.session_state.messages:
                with st.chat_message(message["role"]):
                    st.markdown(message["content"])
            chat_history.markdown("</div>", unsafe_allow_html=True)
        if prompt:
            st.session_state.messages.append({"role": "user", "content": prompt})
            with st.chat_message("user"):
                st.markdown(prompt)
            with st.chat_message("assistant"):
                with st.spinner("Thinking..."):
                    response = self.process_chat_query(prompt, with_frame=False)
                    st.markdown(response)
                    st.session_state.messages.append({"role": "assistant", "content": response})

    def run(self):
        st.title("S3 Video Streamer with Subtitles")
        col1, col2 = st.columns([3, 1])
        with col1:
            # Load Spark catalog table instead of CSV
            df = self.load_catalog_table()
            if df is not None:
                video_id = st.selectbox("Select a Video ID:", df['video_id'].unique())
                if video_id:
                    filtered_files = df[df['video_id'] == video_id]
                    video_file = filtered_files[filtered_files['local_file'].str.contains("_full.mp4")]['s3_key'].values[0]
                    if video_file:
                        video_url = self.get_presigned_url(video_file)
                        if video_url:
                            st.video(video_url, format="video/mp4", start_time=0)
                            vtt_files = filtered_files[filtered_files['local_file'].str.contains(".vtt")]['s3_key'].values
                            if len(vtt_files) > 0:
                                vtt_file = vtt_files[0]
                                vtt_url = self.get_presigned_url(vtt_file)
                                if vtt_url:
                                    st.write("Subtitles (Preview):")
                                    response = self.s3_client.get_object(Bucket=self.s3_bucket, Key=vtt_file)
                                    self.vtt_content = response['Body'].read().decode('utf-8')
                                    st.text(self.vtt_content)
                                else:
                                    st.warning("Failed to load subtitles.")
                            else:
                                st.info("No subtitles available for this video.")
                    else:
                        st.error("Video file not found.")
        with col2:
            handle_vimeo_url()
            self.display_chat()

if __name__ == "__main__":
    app = S3VideoStreamer()
    app.run()

import streamlit as st
import boto3
import logging
import pandas as pd
import openai
import base64
from botocore.exceptions import NoCredentialsError
import subprocess
import asyncio


# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Function to run the bash script asynchronously
async def run_bash_script(url):
    # Call the bash script with the URL as an argument
    process = await asyncio.create_subprocess_exec(
        '/opt/streamscribe/vid_down.sh', url,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    
    # Capture output and errors
    stdout, stderr = await process.communicate()

    # Return the result or error
    if process.returncode == 0:
        return stdout.decode()  # Return script output
    else:
        return stderr.decode()  # Return error output

# Function to handle the input and run the script
def handle_vimeo_url():

    # Input field for Vimeo URL
    vimeo_url = st.text_input("Enter Vimeo Video URL:")

    if vimeo_url:
        # Display a loading spinner while the script is running
        with st.spinner("Downloading video..."):
            # Run the bash script asynchronously and get the output
            result = asyncio.run(run_bash_script(vimeo_url))
            # Display the result
            st.text(result)

            # Reload the page once the download is complete
            st.rerun()


class S3VideoStreamer:
    def __init__(self):
        """Initialize the file streamer."""
        self.s3_bucket = st.secrets["aws"]["S3_BUCKET_NAME"]
        self.s3_client = boto3.client('s3')
        self.csv_file_path = "uploaded_files.csv"
        self.vtt_content = ""
    
    def initialize_openai(self):
        """Initialize OpenAI API with error handling"""
        try:
            openai.api_key = st.secrets["OPENAI_API_KEY"]
        except KeyError:
            st.error("Please set your OpenAI API key in Streamlit secrets.")
            st.stop()
        
    def load_csv(self):
        """
        Load the CSV file containing file metadata.
        Returns:
            DataFrame: DataFrame with file metadata.
        """
        try:
            return pd.read_csv(self.csv_file_path, names=["VideoID", "S3Key", "FileName"])
        except FileNotFoundError:
            st.error("CSV file not found. Please check the file path.")
            return None
        except Exception as e:
            st.error(f"Failed to load CSV file: {str(e)}")
            return None

    def get_presigned_url(self, s3_key):
        """
        Generate a pre-signed URL for file access.
        Args:
            s3_key (str): Key of the S3 object to generate the URL for.
        Returns:
            str: Pre-signed URL.
        """
        try:
            url = self.s3_client.generate_presigned_url(
                'get_object',
                Params={'Bucket': self.s3_bucket, 'Key': s3_key},
                ExpiresIn=3600  # URL valid for 1 hour
            )
            return url
        except NoCredentialsError:
            st.error("AWS credentials not found.")
            return None
        except Exception as e:
            st.error(f"Error generating pre-signed URL: {str(e)}")
            return None
    
    def process_chat_query(self, query, with_frame=False):
        """Process user query with optional frame capture"""
        try:
           # timestamp = #st.session_state.current_timestamp
            context = self.vtt_content#self.get_context_from_timestamp(timestamp)
            
            if not with_frame:
                # Using GPT-4 for text-only queries
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
            
            # Extract response text
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
        """Handle the chat functionality."""
        st.subheader("Chat")

        # Initialize session_state.messages if it doesn't exist
        if "messages" not in st.session_state:
            st.session_state.messages = []

        # Create a container for chat history
        chat_container = st.container()

        # Chat history section: make it scrollable within the container
        with chat_container:
            # Set the scrollable area
            prompt = st.chat_input("Ask about the video...")
            chat_history = st.empty()  # Empty container to hold the chat messages
            chat_history.markdown("<div style='height: 300px; overflow-y: scroll;'>", unsafe_allow_html=True)  # You can adjust height as needed
            
            for message in reversed(st.session_state.messages):  # Reverse the message list to show the latest first
                with st.chat_message(message["role"]):
                    st.markdown(message["content"])
            
            chat_history.markdown("</div>", unsafe_allow_html=True)

        # Chat input section at the bottom
        if prompt:
            # Add user message
            st.session_state.messages.append({"role": "user", "content": prompt})
            with st.chat_message("user"):
                st.markdown(prompt)

            # Generate and add assistant response
            with st.chat_message("assistant"):
                with st.spinner("Thinking..."):
                    response = self.process_chat_query(prompt, with_frame=False)  # Or True if you want to capture frames
                    st.markdown(response)
                    st.session_state.messages.append({"role": "assistant", "content": response})

    def run(self):
        """Run the Streamlit application."""
        st.title("S3 Video Streamer with Subtitles")

        # Create two columns for video and chat
        col1, col2 = st.columns([3, 1])  # Adjust the ratio of the columns as needed

        # Video section on the left
        with col1:
            # Load CSV file
            df = self.load_csv()
            if df is not None:
                # Select Video ID
                video_id = st.selectbox("Select a Video ID:", df['VideoID'].unique())

                if video_id:
                    # Filter files for the selected Video ID
                    filtered_files = df[df['VideoID'] == video_id]
                    
                    # Video file (e.g., video_full.mp4)
                    video_file = filtered_files[filtered_files['FileName'].str.contains("_full.mp4")]['S3Key'].values[0]
                    
                    if video_file:
                        # Generate pre-signed URLs
                        video_url = self.get_presigned_url(video_file)
                        if video_url:
                            # Display the video
                            st.video(video_url, format="video/mp4", start_time=0)

                            # Check if VTT file exists
                            vtt_files = filtered_files[filtered_files['FileName'].str.contains(".vtt")]['S3Key'].values
                            if len(vtt_files) > 0:
                                vtt_file = vtt_files[0]
                                vtt_url = self.get_presigned_url(vtt_file)
                                if vtt_url:
                                    # Fetch and display the VTT subtitles as plain text
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
        
        # Chat section on the right
        with col2:
            handle_vimeo_url()
            self.display_chat()


# Run the app
if __name__ == "__main__":
    app = S3VideoStreamer()
    app.run()

from pyspark.sql import SparkSession

# Start Spark session
spark = SparkSession.builder.appName("UploadCatalog").getOrCreate()

# Read the CSV file into a DataFrame
df = spark.read.option("header", "false").csv("uploaded_files.csv")
df = df.toDF("video_id", "s3_key", "local_file")

# Table name and database (change as needed)
table_name = "default.uploaded_files_catalog"

# Check if table exists
if spark.catalog.tableExists(table_name):
    # Append to existing table
    df.writeTo(table_name).append()
else:
    # Create new table
    df.writeTo(table_name).create()
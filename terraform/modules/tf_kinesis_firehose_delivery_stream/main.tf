// AWS Firehose Stream: StreamAlert Data
//
// This resource is broken out into its own module due to the way
// Terraform handles list interpolation on resources.
//

locals {
  data_location       = "s3://${var.prefix}-streamalert-data/${var.log_name}"
  ser_de_params_key   = var.store_format == "parquet" ? "serialization.format" : "ignore.malformed.json"
  ser_de_params_value = var.store_format == "parquet" ? "1" : "true"
}

resource "aws_kinesis_firehose_delivery_stream" "streamalert_data" {
  name        = "${var.use_prefix ? "${var.prefix}_" : ""}streamalert_data_${var.log_name}"
  destination = var.store_format == "parquet" ? "extended_s3" : "s3"

  // AWS Firehose Stream for data to S3 and saved in JSON format
  dynamic "s3_configuration" {
    for_each = var.store_format == "parquet" ? [] : [var.store_format]
    content {
      role_arn           = var.role_arn
      bucket_arn         = "arn:aws:s3:::${var.s3_bucket_name}"
      prefix             = "${var.log_name}/"
      buffer_size        = var.buffer_size
      buffer_interval    = var.buffer_interval
      compression_format = "GZIP"
      kms_key_arn        = var.kms_key_arn
    }
  }

  // AWS Firehose Stream for data to S3 and saved in Parquet format
  dynamic "extended_s3_configuration" {
    for_each = var.store_format == "parquet" ? [var.store_format] : []
    content {
      role_arn            = var.role_arn
      bucket_arn          = "arn:aws:s3:::${var.s3_bucket_name}"
      prefix              = "${var.log_name}/dt=!{timestamp:yyyy-MM-dd-HH}/"
      error_output_prefix = "${var.log_name}/!{firehose:error-output-type}/"
      buffer_size         = var.buffer_size
      buffer_interval     = var.buffer_interval

      # The S3 destination's compression format must be set to UNCOMPRESSED
      # when data format conversion is enabled.
      compression_format = "UNCOMPRESSED"
      kms_key_arn        = var.kms_key_arn

      data_format_conversion_configuration {
        input_format_configuration {
          deserializer {
            # # more resilient with log schemas that have nested JSON comparing to hive_json_ser_de
            open_x_json_ser_de {}
          }
        }
        output_format_configuration {
          serializer {
            parquet_ser_de {}
          }
        }
        schema_configuration {
          database_name = var.glue_catalog_db_name
          role_arn      = var.role_arn
          table_name    = var.glue_catalog_table_name
        }
      }
    }
  }

  depends_on = [aws_glue_catalog_table.data]

  tags = {
    Name = "StreamAlert"
  }
}

// AWS CloudWatch Metric Alarm for this Firehose
resource "aws_cloudwatch_metric_alarm" "firehose_records_alarm" {
  count               = var.enable_alarm ? 1 : 0
  alarm_name          = "${aws_kinesis_firehose_delivery_stream.streamalert_data.name}_record_count"
  namespace           = "AWS/Firehose"
  metric_name         = "IncomingRecords"
  statistic           = "Sum"
  comparison_operator = "LessThanThreshold"
  threshold           = var.alarm_threshold
  evaluation_periods  = var.evaluation_periods
  period              = var.period_seconds
  alarm_description   = "StreamAlert Firehose record count less than expected threshold: ${var.log_name}"
  alarm_actions       = var.alarm_actions

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.streamalert_data.name
  }

  tags = {
    Name = "StreamAlert"
  }
}

// data athena table
resource "aws_glue_catalog_table" "data" {
  count         = var.store_format == "parquet" ? 1 : 0
  name          = var.log_name
  database_name = var.glue_catalog_db_name

  table_type = "EXTERNAL_TABLE"

  # parameters = {
  #   EXTERNAL              = "TRUE"
  #   "parquet.compression" = "UNCOMPRESSED"
  # }

  partition_keys {
    name = "dt"
    type = "string"
  }

  storage_descriptor {
    location      = local.data_location
    input_format  = var.store_format == "parquet" ? "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat" : "org.apache.hadoop.mapred.TextInputFormat"
    output_format = var.store_format == "parquet" ? "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat" : "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "${var.store_format}_ser_de"
      serialization_library = var.store_format == "parquet" ? "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe" : "org.openx.data.jsonserde.JsonSerDe"
      parameters            = map(local.ser_de_params_key, local.ser_de_params_value)
    }

    dynamic "columns" {
      for_each = var.schema
      content {
        name = columns.value[0]
        type = columns.value[1]
      }
    }
  }
}

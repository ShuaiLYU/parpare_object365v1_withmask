#!/bin/bash

################################################################################
#                           YOLO-E Data Preparation Script                     #
#                       Cross-platform (Linux & macOS)                        #
################################################################################
# 
# Description: This script downloads and prepares datasets for YOLO-E training
# Datasets: Objects365, GQA, Flickr30k, LVIS
# Author: YourName
# Date: $(date +%Y-%m-%d)
#
################################################################################

echo "🚀 Starting Objects365_v1 Preparation..."
echo "════════════════════════════════════════════════════════════════════════"

#===============================================================================
#                               SYSTEM DETECTION
#===============================================================================

# Detect operating system
OS="$(uname -s)"
case "${OS}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
    CYGWIN*)    MACHINE=Cygwin;;
    MINGW*)     MACHINE=MinGw;;
    *)          MACHINE="UNKNOWN:${OS}"
esac

echo "📋 Detected OS: ${MACHINE}"
echo "────────────────────────────────────────────────────────────────────────"

#===============================================================================
#                               UTILITY FUNCTIONS
#===============================================================================

# Function to download files - uses wget on Linux, curl on macOS
download_file() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry_count=0
    
    echo "Downloading: $(basename "$output")"
    
    while [ $retry_count -lt $max_retries ]; do
        if [ "$MACHINE" = "Linux" ]; then
            # Check if wget is available, if not try curl
            if command -v wget >/dev/null 2>&1; then
                echo "Using wget to download: $url (attempt $((retry_count + 1))/$max_retries)"
                # Use wget with timeout, retries, and continue on partial downloads
                wget --timeout=30 --tries=3 --continue "$url" -O "$output" && {
                    echo "Successfully downloaded: $(basename "$output")"
                    return 0
                }
            elif command -v curl >/dev/null 2>&1; then
                echo "wget not found, using curl to download: $url (attempt $((retry_count + 1))/$max_retries)"
                # Use curl with timeout, retries, and resume capability
                curl --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 5 -C - -L "$url" -o "$output" && {
                    echo "Successfully downloaded: $(basename "$output")"
                    return 0
                }
            else
                echo "Error: Neither wget nor curl is available. Please install one of them."
                exit 1
            fi
        elif [ "$MACHINE" = "Mac" ]; then
            # macOS - use curl (which is built-in)
            if command -v curl >/dev/null 2>&1; then
                echo "Using curl to download: $url (attempt $((retry_count + 1))/$max_retries)"
                # Use curl with timeout, retries, and resume capability
                curl --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 5 -C - -L "$url" -o "$output" && {
                    echo "Successfully downloaded: $(basename "$output")"
                    return 0
                }
            else
                echo "Error: curl is not available on macOS (this shouldn't happen)"
                exit 1
            fi
        else
            echo "Error: Unsupported operating system: $MACHINE"
            exit 1
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo "Download failed, retrying in 10 seconds... (attempt $((retry_count + 1))/$max_retries)"
            sleep 10
        fi
    done
    
    echo "Error: Failed to download $url after $max_retries attempts"
    return 1
}

#-------------------------------------------------------------------------------
# Function to download files using aria2 for faster speeds - cross-platform
#-------------------------------------------------------------------------------
aria2_download_file() {
    local url="$1"
    local output="$2"
    local connections="${3:-8}"      # Default 8 connections
    local max_retries=3
    local retry_count=0
    
    echo "Downloading with aria2: $(basename "$output")"
    
    # Check if aria2c is available
    if ! command_exists aria2c; then
        echo "aria2c not found. Please install aria2:"
        if [ "$MACHINE" = "Linux" ]; then
            echo "  Ubuntu/Debian: sudo apt-get install aria2"
            echo "  CentOS/RHEL:   sudo yum install aria2"
        elif [ "$MACHINE" = "Mac" ]; then
            echo "  macOS: brew install aria2"
            echo "  Or download from: https://aria2.github.io/"
        fi
        echo "Falling back to standard download..."
        return 1
    fi
    
    # Prepare output directory
    local output_dir=$(dirname "$output")
    local output_filename=$(basename "$output")
    mkdir -p "$output_dir"
    
    while [ $retry_count -lt $max_retries ]; do
        echo "Using aria2c to download: $url (attempt $((retry_count + 1))/$max_retries)"
        echo "Connections: $connections, Output: $output"
        
        # aria2c arguments for optimized download
        local aria2_args=(
            "--max-connection-per-server=$connections"
            "--split=$connections"
            "--max-concurrent-downloads=1"
            "--continue=true"
            "--retry-wait=5"
            "--max-tries=1"              # We handle retries manually
            "--timeout=30"
            "--connect-timeout=10"
            "--summary-interval=10"
            "--console-log-level=notice"
            "--allow-overwrite=true"
            "--auto-file-renaming=false"
            "--dir=$output_dir"
            "--out=$output_filename"
        )
        
        # Execute aria2c
        if aria2c "${aria2_args[@]}" "$url"; then
            echo "Successfully downloaded: $(basename "$output") using aria2"
            return 0
        else
            echo "aria2c download failed (attempt $((retry_count + 1))/$max_retries)"
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo "Download failed, retrying in 10 seconds... (attempt $((retry_count + 1))/$max_retries)"
            sleep 10
        fi
    done
    
    echo "Error: Failed to download $url with aria2 after $max_retries attempts"
    echo "Falling back to standard download..."
    return 1
}

#-------------------------------------------------------------------------------
# Smart download function - tries aria2 first, falls back to standard download
#-------------------------------------------------------------------------------
smart_download_file() {
    local url="$1"
    local output="$2"
    local connections="${3:-8}"
    
    echo "Starting smart download for: $(basename "$output")"
    
    # Try aria2 first if available
    if command_exists aria2c; then
        echo "aria2c detected, using fast download..."
        if aria2_download_file "$url" "$output" "$connections"; then
            return 0
        else
            echo "aria2 download failed, falling back to standard download..."
        fi
    else
        echo "aria2c not available, using standard download..."
    fi
    
    # Fallback to standard download
    download_file "$url" "$output"
}

#-------------------------------------------------------------------------------
# Function to download from HuggingFace with multiple mirror fallbacks
#-------------------------------------------------------------------------------
download_huggingface_mirror() {
    local hf_url="$1"
    local output="$2"
    local filename=$(basename "$output")
    local mirrors=(
        "hf-mirror.byteintl.com" 
        "mirror.baai.ac.cn"  
        "hf-mirror.com" 
    )

    echo "Attempting to download: $filename"
    
    # 尝试原始地址（有时可能速度不错）
    if download_file "$hf_url" "$output"; then
        echo "Successfully downloaded from original URL"
        return 0
    fi

    # 依次尝试各个镜像源
    for mirror in "${mirrors[@]}"; do
        local mirror_url="${hf_url/huggingface.co/$mirror}"
        echo "Trying mirror: $mirror"
        if download_file "$mirror_url" "$output"; then
            echo "Successfully downloaded from $mirror"
            return 0
        fi
    done
    
    echo "All sources failed to download $filename"
    return 1
}


#-------------------------------------------------------------------------------
# Function to check if a command exists
#-------------------------------------------------------------------------------
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

#===============================================================================
#                           SYSTEM REQUIREMENTS CHECK
#===============================================================================

# Check for required tools
echo "🔧 Checking for required tools..."
if [ "$MACHINE" = "Linux" ]; then
    if ! command_exists wget && ! command_exists curl; then
        echo "Error: Neither wget nor curl is installed. Please install one of them:"
        echo "  Ubuntu/Debian: sudo apt-get install wget"
        echo "  CentOS/RHEL:   sudo yum install wget"
        echo "  Or:            sudo apt-get install curl"
        exit 1
    fi
elif [ "$MACHINE" = "Mac" ]; then
    if ! command_exists curl; then
        echo "Error: curl is not available (this shouldn't happen on macOS)"
        exit 1
    fi
fi

if ! command_exists unzip; then
    echo "Error: unzip is not installed. Please install it:"
    if [ "$MACHINE" = "Linux" ]; then
        echo "  Ubuntu/Debian: sudo apt-get install unzip"
        echo "  CentOS/RHEL:   sudo yum install unzip"
    elif [ "$MACHINE" = "Mac" ]; then
        echo "  macOS: unzip should be pre-installed. Try: brew install unzip"
    fi
    exit 1
fi

echo "✅ All required tools are available."
echo "════════════════════════════════════════════════════════════════════════"

#===============================================================================
#                           DATASET DIRECTORY SETUP
#===============================================================================

echo "📁 Setting up dataset directories..."



# Create main datasets directory
if [ ! -d datasets ]; then
    mkdir datasets
    echo "📁 Created datasets directory"
fi

echo "────────────────────────────────────────────────────────────────────────"

#===============================================================================
#                         OBJECTS365 DATASET PROCESSING
#===============================================================================

echo "🗃️  Processing Objects365 Dataset..."
echo "────────────────────────────────────────────────────────────────────────" 
# Step 1: Download Objects365 dataset from OpenXLab
if [ ! -d ./datasets/Objects365v1/ ]; then
    echo "📥 Downloading Objects365 dataset from OpenXLab..."
    
    pip install openxlab          # Install OpenXLab CLI
    pip install -U openxlab       # Upgrade to latest version

    # Set OpenXLab credentials
    export OPENXLAB_AK="bjd6a9x4o6jlajl9lq4e"
    export OPENXLAB_SK="ajv2e3wq6ylmnzkgr63bajvajgax85gpr17bzjmq"

    # Login using environment variables (non-interactive)
    openxlab login --ak $OPENXLAB_AK --sk $OPENXLAB_SK
    
    # Download dataset
    openxlab dataset get --dataset-repo OpenDataLab/Objects365_v1 --target-path ./datasets

    # Rename downloaded directory
    mv ./datasets/OpenDataLab___Objects365_v1 ./datasets/Objects365v1
    echo "✅ Objects365 dataset downloaded successfully"
else
    echo "✅ Objects365v1 dataset already exists, skipping download."
fi 

echo "────────────────────────────────────────────────────────────────────────"

# Step 2: Extract Objects365 raw data
if [ ! -d ./datasets/Objects365v1/raw/Objects365_v1 ]; then
    echo "📦 Extracting Objects365_v1 raw data..."
    mkdir -p ./datasets/Objects365v1/raw
    if [ -f ./datasets/Objects365v1/raw/Objects365_v1.tar.gz ]; then
        tar -xzf ./datasets/Objects365v1/raw/Objects365_v1.tar.gz -C ./datasets/Objects365v1/raw/
        echo "✅ Extraction complete."
    else
        echo "❌ Error: Objects365_v1.tar.gz not found in ./datasets/Objects365v1/raw/"
        exit 1
    fi
else
    echo "✅ Objects365_v1 raw data already extracted, skipping."
fi

echo "────────────────────────────────────────────────────────────────────────"

# Step 3: Setup annotations directory and copy base annotations
mkdir -p ./datasets/Objects365v1/annotations 
if [ -f ./datasets/Objects365v1/raw/Objects365_v1/2019-08-02/objects365_train.json ]; then
    cp ./datasets/Objects365v1/raw/Objects365_v1/2019-08-02/objects365_train.json ./datasets/Objects365v1/annotations/
    echo "✅ Copied base Objects365 annotations"
fi

echo "────────────────────────────────────────────────────────────────────────"

# Step 4: Extract training images
if [ ! -d ./datasets/Objects365v1/images/train ]; then
    echo "📦 Extracting Objects365_v1 training images..."
    mkdir -p ./datasets/Objects365v1/images/train
    for part in ./datasets/Objects365v1/raw/Objects365_v1/2019-08-02/train_part*.zip; do
        if [ -f "$part" ]; then
            echo "📦 Extracting $(basename "$part")..."
            unzip -q "$part" -d ./datasets/Objects365v1/images/
        else
            echo "⚠️  Warning: No train_part*.zip files found in ./datasets/Objects365v1/raw/Objects365_v1/2019-08-02"
            break
        fi
    done
    echo "✅ Extraction of training images complete."
else
    echo "✅ Objects365_v1 training images already extracted, skipping."
fi

echo "────────────────────────────────────────────────────────────────────────"




#===============================================================================

# step 5: Extract validation images
# ./datasets/Objects365v1/raw/Objects365_v1/2019-08-02/val.zip
if [ ! -d ./datasets/Objects365v1/images/val ]; then
    echo "📦 Extracting Objects365_v1 validation images..."
    mkdir -p ./datasets/Objects365v1/images/val
    if [ -f ./datasets/Objects365v1/raw/Objects365_v1/2019-08-02/val.zip ]; then
        unzip -q ./datasets/Objects365v1/raw/Objects365_v1/2019-08-02/val.zip -d ./datasets/Objects365v1/images/
        echo "✅ Extraction of validation images complete."
    else
        echo "❌ Error: val.zip not found in ./datasets/Objects365v1/raw/Objects365_v1/2019-08-02/"
        exit 1
    fi
else
    echo "✅ Objects365_v1 validation images already extracted, skipping."
fi

# check how many images are in train and val directories
train_count=$(find ./datasets/Objects365v1/images/train -type f | wc -l)
val_count=$(find ./datasets/Objects365v1/images/val -type f | wc -l)
echo "📊 Objects365_v1 dataset contains $train_count training images and $val_count validation images."







# Step 6: Download train segmentation annotations from HuggingFace
if [ ! -f ./datasets/Objects365v1/annotations/objects365_train_segm.json ]; then
    echo "📥 Downloading Objects365 training segmentation annotations..."
    download_huggingface_mirror "https://huggingface.co/datasets/jameslahm/yoloe/resolve/main/objects365_train_segm.json" "./datasets/Objects365v1/annotations/objects365_train_segm.json"
    echo "✅ Objects365 segmentation annotations downloaded"
else
    echo "✅ Objects365 training segmentation annotations already exist, skipping download."
fi


echo "────────────────────────────────────────────────────────────────────────"
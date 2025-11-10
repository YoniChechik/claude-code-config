# Album-Maker System Architecture

Album-maker is a Python photo processing pipeline that creates high-quality photo albums through automated trip detection, intelligent photo selection, and creative album generation.

## Core Pipeline
```
Photos → Trip Detection → Photo Selection → Album Generation
```

## Key Components

- **Trip Detection** (`album_maker/algo/trip_detection/`) - Clusters photos by location and temporal patterns
- **Photo Selection** (`album_maker/algo/photo_selection/`) - ML-based quality scoring and deduplication
- **Trip LLM Naming** (`album_maker/algo/trip_naming/`) - Creative title generation and layout optimization
- **Core** (`album_maker/core/`) - Configuration, logging, error handling
    - **Main config**: `album_maker/core/config.py`
    - **Global logger**: `from album_maker.core.log import logger`
- **API** (`album_maker/api/`) - REST endpoints for external integration
- **Inference** (`album_maker/inference/`) - ML model management and embedding generation
- **I/O** (`album_maker/io/`) - EXIF data extraction and photo preprocessing

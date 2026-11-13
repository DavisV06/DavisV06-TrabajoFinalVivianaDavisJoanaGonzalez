"""Model inference: Ben Graham preprocessing, TTA × 8, ResNet50."""

import time
import logging
import os
import cv2
import numpy as np

logger = logging.getLogger(__name__)

_rn50_model = None
_models_loaded = False


def _load_models(rn50_path: str):
    global _rn50_model, _models_loaded
    if _models_loaded:
        return
    try:
        import tensorflow as tf
        logger.info("Loading ResNet50 from %s", rn50_path)
        _rn50_model = tf.keras.models.load_model(rn50_path, compile=False)
        _models_loaded = True
        logger.info("ResNet50 loaded successfully.")
    except Exception as exc:
        logger.error("Failed to load models: %s", exc)
        _models_loaded = False


def init_inference(app):
    """Call from app factory after config is set."""
    _load_models(app.config["MODEL_RN50_PATH"])


# ── Preprocessing ──────────────────────────────────────────────────────────

def load_fundus(image_path: str, size: int = 224) -> np.ndarray:
    """Load the image the way Keras flow_from_directory did during training
    (RGB, nearest-neighbour resize). Resizing with INTER_AREA instead changes
    the high-frequency texture that Ben Graham amplifies and costs ~10 points
    of accuracy.
    """
    from tensorflow.keras.utils import load_img, img_to_array
    img = load_img(image_path, target_size=(size, size))
    return img_to_array(img).astype(np.uint8)


def green_graham(img: np.ndarray, sigma: int = 10) -> np.ndarray:
    """Apply green channel + Ben Graham illumination normalization
    (sigmaX=10, as in training)."""
    g = img[:, :, 1]
    g3 = cv2.merge([g, g, g])
    blur = cv2.GaussianBlur(g3, (0, 0), sigmaX=sigma)
    return cv2.addWeighted(g3, 4, blur, -4, 128)


def _mv2_preprocess(img_array: np.ndarray) -> np.ndarray:
    import tensorflow as tf
    return tf.keras.applications.mobilenet_v2.preprocess_input(
        img_array.astype(np.float32)
    )


def _rn50_preprocess(img_array: np.ndarray) -> np.ndarray:
    import tensorflow as tf
    return tf.keras.applications.resnet50.preprocess_input(
        img_array.astype(np.float32)
    )


# ── TTA ────────────────────────────────────────────────────────────────────

_TTA_N = 8


def _augment(img_array: np.ndarray, seed: int) -> np.ndarray:
    """Apply random augmentation for TTA."""
    rng = np.random.default_rng(seed)
    h, w = img_array.shape[:2]

    # Random flip
    if rng.random() > 0.5:
        img_array = cv2.flip(img_array, 1)

    # Random rotation ±10°
    angle = rng.uniform(-10, 10)
    M = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)
    img_array = cv2.warpAffine(img_array, M, (w, h), borderMode=cv2.BORDER_REFLECT)

    # Random zoom ±5%
    zoom = rng.uniform(0.95, 1.05)
    new_w, new_h = int(w * zoom), int(h * zoom)
    img_zoom = cv2.resize(img_array, (new_w, new_h))
    if zoom > 1:
        x0 = (new_w - w) // 2
        y0 = (new_h - h) // 2
        img_array = img_zoom[y0:y0 + h, x0:x0 + w]
    else:
        pad_x = (w - new_w) // 2
        pad_y = (h - new_h) // 2
        img_array = cv2.copyMakeBorder(img_zoom, pad_y, h - new_h - pad_y,
                                       pad_x, w - new_w - pad_x,
                                       cv2.BORDER_REFLECT)

    # Random brightness
    factor = rng.uniform(0.9, 1.1)
    img_array = np.clip(img_array.astype(np.float32) * factor, 0, 255).astype(np.uint8)

    return img_array


def _tta_probs(model, preproc_fn, base_img: np.ndarray, n: int = _TTA_N) -> np.ndarray:
    """Run TTA and return averaged probability vector.
    Ben Graham is applied after each augmentation, matching the training order."""
    probs = None
    for i in range(n):
        aug = green_graham(_augment(base_img.copy(), seed=i * 37))
        batch = np.expand_dims(preproc_fn(aug.astype(np.float32)), 0)
        p = model.predict(batch, verbose=0).astype(np.float32)
        probs = p if probs is None else probs + p
    return (probs / n)[0]


# ── Public API ─────────────────────────────────────────────────────────────

CLASSES = ["normal", "rd", "glaucoma", "catarata"]


def predict_image(image_path: str) -> dict:
    """Run ResNet50 inference (TTA x8) on an image file.

    Returns:
        {
            "clase": str,            # winning class key
            "confianza": float,      # confidence 0-1
            "probabilidades": dict,  # {class_key: float}
            "ms_computo": int,
            "error": str | None,
        }
    """
    if not _models_loaded:
        return {
            "clase": None, "confianza": None,
            "probabilidades": {c: 0.25 for c in CLASSES},
            "ms_computo": 0,
            "error": "Modelos no cargados",
        }

    try:
        t0 = time.perf_counter()
        base_img = load_fundus(image_path)

        probs = _tta_probs(_rn50_model, _rn50_preprocess, base_img)

        idx   = int(np.argmax(probs))
        clase = CLASSES[idx]
        conf  = float(probs[idx])
        ms    = int((time.perf_counter() - t0) * 1000)

        return {
            "clase": clase,
            "confianza": round(conf, 4),
            "probabilidades": {c: round(float(p), 5) for c, p in zip(CLASSES, probs)},
            "ms_computo": ms,
            "error": None,
        }
    except Exception as exc:
        logger.error("Inference error for %s: %s", image_path, exc)
        return {
            "clase": None, "confianza": None,
            "probabilidades": {c: 0.25 for c in CLASSES},
            "ms_computo": 0,
            "error": str(exc),
        }

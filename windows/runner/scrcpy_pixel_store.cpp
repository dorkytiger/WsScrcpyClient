#include "scrcpy_pixel_store.h"

#include <cstring>
#include <utility>

void PixelBufferStore::PublishDecoded(std::vector<uint8_t>* scratch) {
  if (scratch == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (current_ == nullptr) {
    return;
  }
  const size_t expected = current_->pixels.size();
  if (scratch->size() != expected || latest_.size() != expected) {
    // 尺寸刚变、缓冲还没重建：这一帧先不要（下一个尺寸一致的帧会补上）。
    return;
  }
  latest_.swap(*scratch);
  dirty_ = true;
  published_ = true;
  latency_.MarkPublished();
}

size_t PixelBufferStore::Resize(uint32_t width, uint32_t height,
                                std::vector<uint8_t>* scratch) {
  const size_t bytes = static_cast<size_t>(width) * height * 4;
  std::lock_guard<std::mutex> lock(mutex_);
  // 旧 current_ 不再由我们持有；如果引擎手上还有它的 Grant，那一帧会活到读完之后
  // 才释放（shared_ptr 语义），所以这里不需要任何"延迟释放"列表。
  std::shared_ptr<Frame> frame = std::make_shared<Frame>();
  frame->pixels.assign(bytes, 0);
  frame->width = width;
  frame->height = height;
  current_ = std::move(frame);
  if (scratch != nullptr) {
    scratch->assign(bytes, 0);
  }
  latest_.assign(bytes, 0);
  dirty_ = false;
  return bytes;
}

const FlutterDesktopPixelBuffer* PixelBufferStore::CopyLatest() {
  raster_callbacks_.fetch_add(1);
  std::shared_ptr<Frame> frame;
  bool handed_new_frame = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (current_ == nullptr) {
      return nullptr;
    }
    // 引擎跑在 raster 线程上：把最新一帧**拷**进它要读的那张缓冲，
    // 绝不把解码线程正在写的内存交出去（否则会出现撕裂帧）。
    if (dirty_ && latest_.size() == current_->pixels.size()) {
      std::memcpy(current_->pixels.data(), latest_.data(), latest_.size());
      dirty_ = false;
      handed_new_frame = true;
    }
    frame = current_;  // 留一份引用，交给下面的 Grant
  }
  // 只有"这次真的把一帧新的交出去"才计一个延迟样本（引擎按 vsync 来取，
  // 没有新帧的空取不属于这一帧的延迟，见 present_latency.h）。
  if (handed_new_frame) {
    latency_.MarkPickedUp();
  }

  // 每次回调一张 Grant：descriptor 指向 Grant 自己，release_callback 里把它删掉。
  // 引擎读完（TexImage2D 之后）会调用 release_callback，此时 Grant 与 frame 一起释放。
  Grant* grant = new Grant();
  grant->frame = std::move(frame);
  grant->descriptor.buffer = grant->frame->pixels.data();
  grant->descriptor.width = grant->frame->width;
  grant->descriptor.height = grant->frame->height;
  grant->descriptor.release_callback = [](void* context) {
    delete static_cast<Grant*>(context);
  };
  grant->descriptor.release_context = grant;
  return &grant->descriptor;
}

void PixelBufferStore::Clear() {
  std::lock_guard<std::mutex> lock(mutex_);
  current_.reset();
  latest_.clear();
  dirty_ = false;
  published_ = false;
}

uint32_t PixelBufferStore::width() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return current_ == nullptr ? 0 : current_->width;
}

uint32_t PixelBufferStore::height() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return current_ == nullptr ? 0 : current_->height;
}

bool PixelBufferStore::has_published() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return published_;
}

uint64_t PixelBufferStore::raster_callbacks() const {
  return raster_callbacks_.load();
}

uint64_t PixelBufferStore::present_latency_samples() const {
  return latency_.samples();
}

uint64_t PixelBufferStore::present_latency_sum_us() const {
  return latency_.sum_us();
}

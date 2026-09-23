import UIKit

/// Подготовка фото к отправке на сервер.
///
/// `PhotosPickerItem.loadTransferable(type: Data.self)` отдаёт исходные байты
/// снимка, а камера iPhone по умолчанию снимает в HEIC. Сервер принимает только
/// JPEG/PNG/WebP/GIF (core/Image.php), поэтому большинство фото с камеры
/// отклонялось с «Недопустимый формат изображения». Перекодируем в JPEG и
/// заодно уменьшаем до 2048 px по большей стороне — быстрее грузится по сети.
enum ImageUpload {
    static func jpeg(from data: Data, maxSide: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let longest = max(size.width, size.height)
        var target = image
        if longest > maxSide, longest > 0 {
            let scale = maxSide / longest
            let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            target = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        return target.jpegData(compressionQuality: quality)
    }
}

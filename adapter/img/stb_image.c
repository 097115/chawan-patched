#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_LINEAR
#define STBI_NO_STDIO
/* #define STBI_NO_JPEG
 * #define STBI_NO_PNG
 * #define STBI_NO_BMP
 */
#define STBI_NO_PSD
#define STBI_NO_TGA
/* #define STBI_NO_GIF */
#define STBI_NO_HDR
#define STBI_NO_PIC
#define STBI_NO_PNM /* (.ppm and .pgm) */
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STIBW_NO_STDIO
#include "stb_image_write.h"

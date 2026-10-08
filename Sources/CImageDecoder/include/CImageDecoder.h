#ifndef ADA_IMAGE_DECODER_H
#define ADA_IMAGE_DECODER_H

#ifdef __cplusplus
extern "C" {
#endif

int ada_image_can_decode(const unsigned char *data, int length);
unsigned char *ada_image_decode(const unsigned char *data, int length, int *width, int *height);
void ada_image_free(unsigned char *pixels);

#ifdef __cplusplus
}
#endif

#endif

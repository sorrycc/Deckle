package main

import (
	"bytes"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo/ui"
	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

// decodeFile decodes an image file for an image tab, at most 4096 pixels
// on its longer side, with its own size.
func decodeFile(path string) (ui.ImageSource, float32, float32, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, 0, err
	}
	if strings.EqualFold(filepath.Ext(path), ".svg") {
		s, err := ui.ParseSVG(data)
		if err != nil {
			return nil, 0, 0, err
		}
		w, h := s.Size()
		return s, w, h, nil
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, err
	}
	b := img.Bounds()
	w, h := float32(b.Dx()), float32(b.Dy())
	return ui.NewBitmap(scaleDown(img, 4096)), w, h, nil
}

func scaleDown(img image.Image, longest int) image.Image {
	b := img.Bounds()
	if max(b.Dx(), b.Dy()) <= longest {
		return img
	}
	scale := float64(longest) / float64(max(b.Dx(), b.Dy()))
	dst := image.NewRGBA(image.Rect(0, 0, max(1, int(float64(b.Dx())*scale)), max(1, int(float64(b.Dy())*scale))))
	xdraw.ApproxBiLinear.Scale(dst, dst.Bounds(), img, b, xdraw.Src, nil)
	return dst
}

// decodeThumb is a square image side pixels across, cropped from the
// middle of the picture at path.
func decodeThumb(path string, side int) ui.ImageSource {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		return nil
	}
	b := img.Bounds()
	s := min(b.Dx(), b.Dy())
	crop := image.Rect(b.Min.X+(b.Dx()-s)/2, b.Min.Y+(b.Dy()-s)/2, b.Min.X+(b.Dx()-s)/2+s, b.Min.Y+(b.Dy()-s)/2+s)
	dst := image.NewRGBA(image.Rect(0, 0, side, side))
	xdraw.CatmullRom.Scale(dst, dst.Bounds(), img, crop, xdraw.Src, nil)
	return ui.NewBitmap(dst)
}

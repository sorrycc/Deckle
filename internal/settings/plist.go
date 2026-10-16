package settings

import (
	"bytes"
	"encoding/xml"
	"errors"
	"strconv"
	"strings"
)

// parsePlist reads an XML property list into maps, slices, strings,
// numbers and booleans; dates and data become strings.
func parsePlist(b []byte) (any, error) {
	d := xml.NewDecoder(bytes.NewReader(b))
	d.Strict = false
	for {
		tok, err := d.Token()
		if err != nil {
			return nil, err
		}
		if se, ok := tok.(xml.StartElement); ok && se.Name.Local != "plist" {
			return plistValue(d, se)
		}
	}
}

func plistValue(d *xml.Decoder, se xml.StartElement) (any, error) {
	switch se.Name.Local {
	case "dict":
		m := map[string]any{}
		key := ""
		for {
			tok, err := d.Token()
			if err != nil {
				return nil, err
			}
			switch t := tok.(type) {
			case xml.StartElement:
				if t.Name.Local == "key" {
					var s string
					if err := d.DecodeElement(&s, &t); err != nil {
						return nil, err
					}
					key = s
					continue
				}
				v, err := plistValue(d, t)
				if err != nil {
					return nil, err
				}
				m[key] = v
			case xml.EndElement:
				return m, nil
			}
		}
	case "array":
		var a []any
		for {
			tok, err := d.Token()
			if err != nil {
				return nil, err
			}
			switch t := tok.(type) {
			case xml.StartElement:
				v, err := plistValue(d, t)
				if err != nil {
					return nil, err
				}
				a = append(a, v)
			case xml.EndElement:
				return a, nil
			}
		}
	case "true", "false":
		d.Skip()
		return se.Name.Local == "true", nil
	}
	var s string
	if err := d.DecodeElement(&s, &se); err != nil {
		return nil, err
	}
	switch se.Name.Local {
	case "integer", "real":
		f, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
		if err != nil {
			return nil, errors.New("plist: bad number")
		}
		return f, nil
	}
	return s, nil
}

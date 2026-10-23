//go:build !linux

package retained

import "errors"

var errPlatform = errors.New("retained identity validation requires Linux statx mount IDs and procfs; no state was changed")

func Validate(Spec, string) error          { return errPlatform }
func ValidateRoot(Spec) error              { return errPlatform }
func Provision(Spec, string, string) error { return errPlatform }
func Adopt(Spec, string, string) error     { return errPlatform }

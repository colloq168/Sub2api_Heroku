package service

import (
	"github.com/colloq168/Sub2api_Heroku/internal/config"
	"github.com/colloq168/Sub2api_Heroku/internal/util/responseheaders"
)

func compileResponseHeaderFilter(cfg *config.Config) *responseheaders.CompiledHeaderFilter {
	if cfg == nil {
		return nil
	}
	return responseheaders.CompileHeaderFilter(cfg.Security.ResponseHeaders)
}

package service

import (
	"context"

	"github.com/colloq168/Sub2api_Heroku/internal/pkg/geminicli"
)

// GeminiCliCodeAssistClient calls GeminiCli internal Code Assist endpoints.
type GeminiCliCodeAssistClient interface {
	LoadCodeAssist(ctx context.Context, accessToken, proxyURL string, req *geminicli.LoadCodeAssistRequest) (*geminicli.LoadCodeAssistResponse, error)
	OnboardUser(ctx context.Context, accessToken, proxyURL string, req *geminicli.OnboardUserRequest) (*geminicli.OnboardUserResponse, error)
}

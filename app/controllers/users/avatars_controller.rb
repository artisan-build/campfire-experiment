class Users::AvatarsController < ApplicationController
  include ActiveStorage::Streaming

  rescue_from(ActiveSupport::MessageVerifier::InvalidSignature) { head :not_found }

  def show
    @user = User.from_avatar_token(params[:user_id])

    if stale?(etag: @user)
      expires_in 30.minutes, public: true, stale_while_revalidate: 1.week

      if (avatar_variant = @user.avatar_variant)
        send_blob_stream avatar_variant, disposition: :inline
      elsif @user.bot?
        render_default_bot
      else
        render_initials
      end
    end
  end

  def destroy
    Current.user.avatar.destroy
    redirect_to user_profile_url
  end

  private
    def render_default_bot
      send_file Rails.root.join("app/assets/images/default-bot-avatar.svg"), content_type: "image/svg+xml", disposition: :inline
    end

    def render_initials
      render formats: :svg
    end
end

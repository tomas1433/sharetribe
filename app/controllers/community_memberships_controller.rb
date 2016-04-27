class CommunityMembershipsController < ApplicationController

  before_filter do |controller|
    controller.ensure_logged_in t("layouts.notifications.you_must_log_in_to_view_this_page")
  end

  skip_filter :cannot_access_if_banned
  skip_filter :cannot_access_without_confirmation
  skip_filter :ensure_consent_given
  skip_filter :ensure_user_belongs_to_community

  before_filter :ensure_pending_consent

  Form = EntityUtils.define_builder(
    [:invitation_code, :string],
    [:email, :string],
    [:consent]
  )

  def pending_consent
    render_pending_consent_form(invitation_code: session[:invitation_code])
  end

  def consent_given
    form_params = params[:form] || {}
    values = Form.call(form_params)

    invitation_check = ->() {
      check_invitation(invitation_code: values[:invitation_code], community: @current_community)
    }
    email_check = ->(_) {
      check_allowed_email(address: values[:email], community: @current_community, user: @current_user)
    }
    terms_check = ->(_, _) {
      check_terms(consent: values[:consent], community: @current_community)
    }

    check_result = Result.all(invitation_check, email_check, terms_check)

    check_result.and_then { |invitation_code, email_address, consent|
      update_membership!(membership: membership,
                         invitation_code: invitation_code,
                         email_address: email_address,
                         consent: consent,
                         community: @current_community,
                         user: @current_user)
    }.on_success { |_|

      # Cleanup session
      session[:fb_join] = nil
      session[:invitation_code] = nil

      Delayed::Job.enqueue(CommunityJoinedJob.new(@current_user.id, @current_community.id))
      Delayed::Job.enqueue(SendWelcomeEmail.new(@current_user.id, @current_community.id), priority: 5)

      flash[:notice] = t("layouts.notifications.you_are_now_member")
      redirect_to root

    }.on_error { |msg, data|

      case data[:reason]

      when :invitation_code_invalid_or_used
        flash[:error] = t("community_memberships.consent_given.invitation_code_invalid_or_used")
        logger.info("Invitation code was invalid or used", :membership_email_not_allowed, data)
        render_pending_consent_form(values.except(:invitation_code))

      when :email_not_allowed
        flash[:error] = t("community_memberships.consent_given.email_not_allowed")
        logger.info("Email is not allowed", :membership_email_not_allowed, data)
        render_pending_consent_form(values.except(:email))

      when :email_not_available
        flash[:error] = t("community_memberships.consent_given.email_not_available")
        logger.info("Email is not available", :membership_email_not_available, data)
        render_pending_consent_form(values.except(:email))

      when :consent_not_given
        flash[:error] = t("community_memberships.consent_given.consent_not_given")
        logger.info("Terms were not accepted", :membership_consent_not_given, data)
        render_pending_consent_form(values.except(:consent))

      when :update_failed
        flash[:error] = t("layouts.notifications.joining_community_failed")
        logger.info("Membership update failed", :membership_update_failed, errors: @community_membership.errors.full_messages)
        render_pending_consent_form(values)

      else
        raise ArgumentError.new("Unhandled error case: #{data[:reason]}")
      end
    }
  end

  private

  def render_pending_consent_form(form_values = {})
    values = Form.call(form_values)
    invite_only = @current_community.join_with_invite_only?
    allowed_emails = Maybe(@current_community.allowed_emails).split(",").or_else([])

    render :pending_consent, locals: {
             invite_only: invite_only,
             allowed_emails: allowed_emails,
             has_valid_email_for_community: @current_user.has_valid_email_for_community?(@current_community),
             values: values
           }
  end

  def check_invitation(invitation_code:, community:)
    return Result::Success.new() unless community.join_with_invite_only?

    if !Invitation.code_usable?(invitation_code, community)
      Result::Error.new("Invitation code is not usable", reason: :invitation_code_invalid_or_used, invitation_code: invitation_code)
    else
      Result::Success.new(invitation_code.upcase)
    end
  end

  def check_allowed_email(address:, community:, user:)
    return Result::Success.new() if user.has_valid_email_for_community?(community)

    if !community.email_allowed?(address)
      Result::Error.new("Email is not allowed", reason: :email_not_allowed, email: address)
    elsif !Email.email_available?(address, community.id)
      Result::Error.new("Email is not available", reason: :email_not_available, email: address)
    else
      Result::Success.new(address)
    end
  end

  def check_terms(consent:, community:)
    if consent == "on"
      Result::Success.new(community.consent)
    else
      Result::Error.new("Consent not accepted", reason: :consent_not_given)
    end
  end

  def update_membership!(membership:, invitation_code:, email_address:, consent:, user:, community:)
    make_admin = community.members.count == 0 # First member is the admin

    update_successful = ActiveRecord::Base.transaction do
      Email.create(person_id: user.id, address: email_address, community_id: community.id)

      m_invitation = Maybe(invitation_code).map { |code| Invitation.find_by(code: code) }

      m_invitation.each { |invitation|
        invitation.use_once!
      }

      attrs = {
        consent: consent,
        invitation: m_invitation.or_else(nil),
        status: "accepted"
      }

      attrs[:admin] = true if make_admin

      membership.update_attributes(attrs)
    end

    if update_successful
      Result::Success.new(membership)
    else
      Result::Error.new("Updating membership failed", reason: :update_failed, errors: membership.errors.full_messages)
    end
  end

  def ensure_pending_consent
    if membership.nil?
      report_missing_membership(@current_user, @current_community) if membership.nil?
    elsif membership.accepted?
      flash[:notice] = t("layouts.notifications.you_are_already_member")
      redirect_to root
    elsif !membership.pending_consent?
      redirect_to root
    end
  end

  def report_missing_membership(user, community)
    ArgumentError.new("User doesn't have membership. Don't know how to continue. person_id: #{user.id}, community_id: #{community.id}")
  end

  def membership
    # TODO This should be changed to @current_user.community_membership when the relation is
    # changed to has_one instead of has_many
    @membership ||= @current_user.community_memberships.find_by(community_id: @current_community.id)
  end

  def access_denied
    # Nothing here, just render the access_denied.haml
  end
end

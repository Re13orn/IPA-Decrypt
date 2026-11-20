#pragma once

#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

namespace ipalab {

struct SmsPhone {
    std::int64_t id;
    std::string display;
};

struct SmsChallenge {
    std::vector<SmsPhone> phones;
    std::int64_t already_sent_to = 0;
};

template <class Phones>
bool contains_phone(const Phones& phones, std::int64_t id) {
    return id > 0 && std::any_of(phones.begin(), phones.end(),
                                [id](const auto& phone) { return phone.id == id; });
}

template <class Phones, class ChoosePhone, class SendSMS>
std::int64_t deliver_sms(Phones phones, std::int64_t phone_id, std::int64_t already_sent_to,
                         bool allows_trusted_device, const ChoosePhone& choose_phone, SendSMS send_sms) {
    if (phone_id == already_sent_to) { return phone_id; }
    for (;;) {
        const int status = send_sms(phone_id);
        if (status >= 200 && status < 300) { return phone_id; }
        const bool recoverable = (status >= 500 && status < 600) || status == 423 || status == 429;
        if (!recoverable || !choose_phone || phones.empty()) {
            throw std::runtime_error("Cannot request SMS verification (HTTP " +
                                     std::to_string(status) + ")");
        }
        for (auto& phone : phones) {
            phone.sms_delivery_status = status;
            phone.allows_trusted_device = allows_trusted_device;
        }
        phone_id = choose_phone(phones);
        if (phone_id == 0 && allows_trusted_device) { return 0; }
        if (!contains_phone(phones, phone_id)) {
            throw std::runtime_error("SMS phone selection was canceled or is invalid");
        }
    }
}

template <class Bytes>
SmsChallenge parse_sms_challenge(int status, const Bytes& body) {
    const auto error = [status](const char* detail) {
        return std::runtime_error("Cannot read SMS verification configuration (HTTP " +
                                  std::to_string(status) + "): " + detail);
    };
    if (status != 200 && status != 201 && status != 202) {
        throw error("unexpected status");
    }
    const auto data = nlohmann::json::parse(body, nullptr, false);
    if (!data.is_object()) {
        throw error("no JSON phone configuration");
    }
    const auto nested = data.find("phoneNumberVerification");
    const auto& config = nested != data.end() && nested->is_object() ? *nested : data;

    auto phoneID = [](const nlohmann::json& object) -> std::int64_t {
        const auto field = object.find("id");
        return field != object.end() && field->is_number_integer() ? field->get<std::int64_t>() : 0;
    };
    SmsChallenge challenge;
    const auto append = [&](const nlohmann::json& phone) {
        const auto id = phoneID(phone);
        if (id <= 0) { return; }
        for (const auto& existing : challenge.phones) {
            if (existing.id == id) { return; }
        }
        std::string display;
        for (const auto* name : {"numberWithDialCode", "obfuscatedNumber", "lastTwoDigits"}) {
            const auto value = phone.find(name);
            if (value != phone.end() && value->is_string() && !value->get_ref<const std::string&>().empty()) {
                display = value->get<std::string>();
                if (std::string_view(name) == "lastTwoDigits") { display = "••" + display; }
                break;
            }
        }
        challenge.phones.push_back({id, std::move(display)});
    };
    const auto findField = [&](const char* name) -> const nlohmann::json* {
        const auto field = config.find(name);
        if (field != config.end()) { return &*field; }
        const auto outer = data.find(name);
        return outer != data.end() ? &*outer : nullptr;
    };
    if (const auto* phones = findField("trustedPhoneNumbers"); phones && phones->is_array()) {
        if (phones->size() > 32) { throw error("too many phone choices"); }
        for (const auto& phone : *phones) { append(phone); }
    }
    const auto* selected = findField("phoneNumber");
    if (challenge.phones.empty() && selected && selected->is_object()) { append(*selected); }
    if (challenge.phones.empty()) { throw error("Apple did not return trusted phone numbers"); }

    // Only 201 signals that Apple already requested delivery during discovery.
    if (status == 201) {
        const auto defaultID = selected ? phoneID(*selected) : 0;
        challenge.already_sent_to = defaultID > 0 ? defaultID : challenge.phones.front().id;
    }
    return challenge;
}

} // namespace ipalab

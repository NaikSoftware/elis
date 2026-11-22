#pragma once

#include <QDateTime>
#include <QObject>
#include <QStringList>

// The agents installed for the user, one list for the whole app. Agents install into directories only the user's shell
// startup adds to PATH, so a login shell is asked, and the PATH it gave is kept for running them.
class DetectedLaunchers : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;
    static DetectedLaunchers *instance();
    QStringList ids() const { return m_ids; } // {"terminal"} until the first answer
    QString path() const { return m_path; }
    bool detected() const { return m_detected; }
    void refresh(); // asks again once the last answer is 5 minutes old
    void found(const QStringList &ids, const QString &path);

Q_SIGNALS:
    void changed();

private:
    QStringList m_ids{QStringLiteral("terminal")};
    QString m_path;
    bool m_detected = false;
    QDateTime m_at;
};

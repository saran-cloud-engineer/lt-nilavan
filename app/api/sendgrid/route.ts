import { NextResponse } from 'next/server';
import sendgrid from '@sendgrid/mail';

function escapeHtml(value: string): string {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export async function POST(req: Request) {
  try {
    const body = await req.json();
    const { name, email, phone, message } = body;

    const apiKey = process.env.SENDGRID_API_KEY;
    const toEmail = process.env.SENDGRID_TO_EMAIL;

    if (!apiKey) {
      console.error('SENDGRID_API_KEY is not set');
      return NextResponse.json({ error: 'SendGrid API key not configured' }, { status: 500 });
    }

    if (!toEmail) {
      console.error('SENDGRID_TO_EMAIL is not set');
      return NextResponse.json({ error: 'Recipient email not configured' }, { status: 500 });
    }

    sendgrid.setApiKey(apiKey);

    const msg = {
      to: toEmail,
      from: toEmail, // Must be a verified sender in SendGrid
      subject: 'New Contact Form Submission',
      text: `Name: ${name}\nEmail: ${email}\nPhone: ${phone}\nMessage: ${message}`,
      html: `
        <html>
          <body style="background: #f6f6f7; padding: 40px 0;">
            <div style="max-width: 480px; margin: 40px auto; background: #fff; border-radius: 18px; box-shadow: 0 2px 8px rgba(0,0,0,0.04); padding: 32px 32px 24px 32px; font-family: Arial, sans-serif;">
              <div style="text-align: center; margin-bottom: 24px;">
                <div style="font-size: 22px; font-weight: bold; letter-spacing: 1px; color: #222;">NILAVAN REALTORS</div>
              </div>
              <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;" />
              <div style="font-size: 16px; color: #222; margin-bottom: 24px;">
                <p style="margin: 0 0 16px 0;">You have a new contact form submission:</p>
                <p style="margin: 0 0 8px 0;"><strong>Name:</strong> ${escapeHtml(name)}</p>
                <p style="margin: 0 0 8px 0;"><strong>Email:</strong> ${escapeHtml(email)}</p>
                <p style="margin: 0 0 8px 0;"><strong>Phone:</strong> ${escapeHtml(phone)}</p>
                <p style="margin: 0 0 8px 0;"><strong>Message:</strong> ${escapeHtml(message)}</p>
              </div>
            </div>
          </body>
        </html>
      `,
    };

    await sendgrid.send(msg);
    return NextResponse.json({ success: true });
  } catch (error: unknown) {
    console.error('SendGrid Error:', error);
    
    if (error && typeof error === 'object' && 'response' in error) {
      const sgError = error as { response?: { body?: unknown } };
      console.error('SendGrid Response Body:', sgError.response?.body);
    }
    
    return NextResponse.json({ error: 'Error sending email' }, { status: 500 });
  }
} 